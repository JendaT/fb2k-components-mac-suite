// Archive unpacking for `intake scan` (pre-resolve). Unpack goes to a sibling
// `<name>.unpacked/` dir; originals are kept until gc (doc 01).
//
// Extraction writes into the sibling `<name>.unpacked.partial/` and renames it
// to `<name>.unpacked/` only after the tool exits 0, so `<name>.unpacked/`
// exists only for a clean extraction. A failed run removes the partial dir; a
// crashed run leaves it behind, where walkDirs never enters it and the next
// scan removes it before retrying. The partial dir is a sibling, so the rename
// never crosses a volume.
//
// A tool run has a hard time limit (UNPACK_TIMEOUT_MS): a hung tool is killed
// and the archive fails. While a tool runs, SIGTERM, SIGINT and SIGHUP kill
// it and remove the partial dir before intake ends (see runTool).

import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
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
 *   with any non-ASCII name goes to 7-Zip instead, see zipSevenZipPlan.)
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

interface SevenZipZipPlan {
  sevenZip: string;
  /** Code-page names: 7-Zip extracts a copy with them decoded to UTF-8. */
  codePage: { cd: CentralDirectory; cp: CodePage } | null;
}

/**
 * A zip with any non-ASCII name byte goes to 7-Zip; pure-ASCII names stay
 * with unzip. macOS's unzip ignores the UTF-8 flag: for entries made on
 * MS-DOS/FAT hosts (what Windows tools write) it translates the name bytes
 * as OEM text, and APFS and SMB refuse the result ("Illegal byte sequence").
 * - Names all UTF-8 (flagged, or unflagged and valid UTF-8): 7-Zip extracts
 *   the zip itself.
 * - Some name neither flagged nor valid UTF-8: raw Windows code-page bytes,
 *   which 7-Zip on macOS does not decode either (it ignores `-mcp`). The
 *   names are decoded here with the code page chooseCodePage picks, into a
 *   copy of the zip that carries them as flagged UTF-8, and 7-Zip extracts
 *   that copy.
 * Returns null for a zip that goes to unzip: names all ASCII, or a central
 * directory zipnames.ts does not read (ZIP64, a split or damaged archive),
 * whose names are unknown. Returns a string (the error) when 7-Zip is needed
 * and none is on PATH.
 */
function zipSevenZipPlan(archivePath: string): SevenZipZipPlan | string | null {
  const cd = readCentralDirectory(archivePath);
  if (cd === null || !cd.entries.some((e) => e.name.some((b) => b >= 0x80))) return null;
  const sevenZip = findSevenZip();
  if (needsCodePage(cd)) {
    const { cp } = chooseCodePage(cd, archivePath);
    if (sevenZip === null) return `zip names are cp${cp}, not UTF-8: extracting them needs 7zz or 7z on PATH`;
    return { sevenZip, codePage: { cd, cp } };
  }
  if (sevenZip === null) return "zip names are non-ASCII UTF-8: extracting them needs 7zz or 7z on PATH";
  return { sevenZip, codePage: null };
}

/** Hard limit on one unpack tool run. */
export const UNPACK_TIMEOUT_MS = 30 * 60 * 1000;

/** Signals that end intake while a tool runs; the tool and the partial dir go first. */
const STOP_SIGNALS = ["SIGTERM", "SIGINT", "SIGHUP"] as const;

/** How long a signalled intake waits for the killed tool before it cleans up and ends anyway. */
const STOP_GRACE_MS = 5000;

const formatDuration = (ms: number): string =>
  ms % 60_000 === 0 ? `${ms / 60_000} min` : ms % 1000 === 0 ? `${ms / 1000} s` : `${ms} ms`;

interface ToolRun {
  code: number;
  stderr: string;
  timedOut: boolean;
}

/**
 * Run an unpack tool (stdin ignored, stdout discarded, stderr collected) in
 * its own process group, so a kill reaches every process of it: Homebrew's
 * `7z` is a shell wrapper that runs p7zip as a child, and killing only the
 * wrapper would leave p7zip writing. The group is SIGKILLed when the run
 * exceeds `timeoutMs`, and the result is then `timedOut`.
 *
 * While the tool runs, SIGTERM, SIGINT and SIGHUP are caught: the group is
 * killed, `cleanup` runs once the tool has exited (or after STOP_GRACE_MS, for
 * a tool stuck in the kernel), and intake re-raises the signal to end as it
 * would have without the handler. A tool in its own group would not get a
 * terminal's SIGINT or SIGHUP, and nothing forwards a SIGTERM sent to intake.
 * The handlers exist only during the run. SIGKILL cannot be caught: a partial
 * dir left by it is removed by the next scan.
 */
async function runTool(argv: string[], timeoutMs: number, cleanup: () => void): Promise<ToolRun> {
  const proc = Bun.spawn(argv, { stdin: "ignore", stdout: "ignore", stderr: "pipe", detached: true });
  const killGroup = () => {
    try {
      process.kill(-proc.pid, "SIGKILL");
    } catch {
      // already gone
    }
  };
  // Drain stderr while waiting: a tool that fills the pipe would block forever.
  const chunks: Uint8Array[] = [];
  const reader = proc.stderr.getReader();
  const drained = (async () => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return;
        chunks.push(value);
      }
    } catch {
      // cancelled after a kill
    }
  })();

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    killGroup();
  }, timeoutMs);

  let signal: NodeJS.Signals | null = null;
  let stopped = false;
  const removeHandlers = () => {
    for (const s of STOP_SIGNALS) process.off(s, onSignal);
  };
  const stop = (s: NodeJS.Signals) => {
    if (stopped) return;
    stopped = true;
    try {
      cleanup();
    } catch {
      // best effort; the next scan removes a leftover partial dir
    }
    removeHandlers();
    process.kill(process.pid, s);
  };
  function onSignal(s: NodeJS.Signals) {
    if (signal !== null) return;
    signal = s;
    clearTimeout(timer);
    killGroup();
    setTimeout(() => stop(s), STOP_GRACE_MS);
  }
  for (const s of STOP_SIGNALS) process.on(s, onSignal);

  try {
    const code = await proc.exited;
    if (signal !== null) {
      stop(signal);
      await new Promise(() => {}); // the re-raised signal ends the process
    }
    if (timedOut) void reader.cancel().catch(() => {});
    else await drained;
    return { code, stderr: Buffer.concat(chunks).toString(), timedOut };
  } finally {
    clearTimeout(timer);
    removeHandlers();
  }
}

export interface UnpackOptions {
  /** Overrides UNPACK_TIMEOUT_MS (tests). */
  timeoutMs?: number;
}

export async function unpackArchive(archivePath: string, dryRun: boolean, opts: UnpackOptions = {}): Promise<UnpackResult> {
  const x = ext(archivePath);
  const stem = archivePath.slice(0, -(x.length + 1));
  const target = stem + ".unpacked";
  const partial = stem + PARTIAL_UNPACK_SUFFIX;
  if (existsSync(target)) return { archive: archivePath, target, action: "already_unpacked" };
  const sevenZipZip = x === "zip" ? zipSevenZipPlan(archivePath) : null;
  if (typeof sevenZipZip === "string") return { archive: archivePath, target, action: "failed", error: sevenZipZip };
  const args = sevenZipZip === null ? extractArgv(x, archivePath, partial) : null;
  if (sevenZipZip === null && args === null)
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
  const timeoutMs = opts.timeoutMs ?? UNPACK_TIMEOUT_MS;
  // On a stop signal: the partial dir and the zip copy, as on any failure.
  const cleanupOnSignal = () => {
    rmSync(partial, { recursive: true, force: true });
    if (copyDir !== null) rmSync(copyDir, { recursive: true, force: true });
  };
  try {
    // A leftover from a run that died mid-extraction.
    rmSync(partial, { recursive: true, force: true });
    mkdirSync(partial, { recursive: true });
    let argv: string[];
    if (sevenZipZip?.codePage) {
      const { cd, cp } = sevenZipZip.codePage;
      // Local temp dir, not the income volume: the copy is as large as the zip.
      copyDir = mkdtempSync(join(tmpdir(), "intake-zip-"));
      const copy = join(copyDir, "utf8-names.zip");
      writeUtf8NamedCopy(archivePath, copy, cd, cp);
      argv = sevenZipArgv(sevenZipZip.sevenZip, copy, partial);
    } else if (sevenZipZip) {
      argv = sevenZipArgv(sevenZipZip.sevenZip, archivePath, partial);
    } else {
      argv = args!;
    }
    const run = await runTool(argv, timeoutMs, cleanupOnSignal);
    if (run.timedOut) return failed(`${basename(argv[0]!)} timed out after ${formatDuration(timeoutMs)}`);
    // Any non-zero exit is a failure, even when files appeared (7-Zip exits 1
    // or 2 after writing the members it could): the partial dir goes.
    if (run.code !== 0) return failed(run.stderr.trim().slice(0, 200) || `${argv[0]} exited ${run.code}`);
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
