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
// it and remove the partial dir before intake ends (runTool, src/proc.ts).
//
// rar is checked by intake itself, because bsdtar's exit code cannot be
// trusted for it (src/rarheaders.ts): the headers are read before anything
// is written, and a refused archive (multi-volume, encrypted, BLAKE2-only,
// damaged, ...) fails with nothing created. After the tool exits 0, every
// data entry of the extracted tree is checked against its header size and
// CRC32, and a missing entry, a mismatch or a file the headers do not list
// fails the archive into the usual partial-dir cleanup. The check runs after
// whichever tool extracted.
//
// A solid RAR4 goes to unar (The Unarchiver's CLI) when it is on PATH:
// libarchive 3.7.4 cannot extract one (it writes the first member, then
// fails). Without unar it is refused before anything is written. Every other
// rar goes to bsdtar, else 7-Zip (extractArgv). unar runs like the other
// tools (runTool, partial dir, owner-writable, symlinks stripped, header
// check).
//
// The tools restore an archive's read-only modes: bsdtar keeps a RAR entry's
// 0555 / 0444 even with `--no-same-permissions` (and maps RAR's Windows
// read-only attribute the same way), unzip and 7-Zip restore Unix modes and
// unzip maps the DOS read-only bit to 0444. (unar 1.10.7 does not: it adds
// u+rw, applies the umask and drops setuid/setgid, and ignores the Windows
// read-only, hidden and system attributes.) A 0555 dir holding a file cannot
// be removed by its owner, and a 0444 copy cannot be tagged. So after every
// tool run, and before any partial dir is removed, the tree is made
// owner-writable (makeOwnerWritable), user-immutable flags (uchg) included.

import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { clearImmutableTree } from "./fflags.ts";
import { runTool } from "./proc.ts";
import { readRarHeaders, verifyRarExtraction, type RarHeaders } from "./rarheaders.ts";
import { ext, PARTIAL_UNPACK_SUFFIX } from "./util.ts";
import {
  chooseCodePage, needsCodePage, readCentralDirectory, undecodableNames, writeUtf8NamedCopy, type CentralDirectory,
  type CodePage, type CodePageChoice,
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

/**
 * Clear uchg on `dir` and everything under it (one chflags spawn, no symlink
 * followed; an immutable entry cannot be chmodded, renamed or removed), then
 * add u+rwx to every dir and u+rw to every regular file. Best effort: an
 * entry that cannot be read or changed is left as it is (a later removal or
 * write then reports it). Only uchg is cleared, never uappnd, schg or sappnd.
 */
function makeOwnerWritable(dir: string): void {
  try {
    if (!lstatSync(dir).isDirectory()) return;
  } catch {
    return;
  }
  clearImmutableTree(dir);
  addOwnerModes(dir);
}

/**
 * Add u+rwx to `dir` and every dir under it, and u+rw to every regular file.
 * Each entry is lstat'ed and a symlink is never followed or chmodded. A dir is
 * changed before it is listed, so a dir without u+r or u+x can still be
 * walked.
 */
function addOwnerModes(dir: string): void {
  let st;
  try {
    st = lstatSync(dir);
  } catch {
    return;
  }
  if (!st.isDirectory()) return;
  try {
    if ((st.mode & 0o700) !== 0o700) chmodSync(dir, (st.mode & 0o7777) | 0o700);
  } catch {
    // left as it is
  }
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return;
  }
  for (const n of names) {
    const p = join(dir, n);
    let s;
    try {
      s = lstatSync(p);
    } catch {
      continue;
    }
    if (s.isDirectory()) {
      addOwnerModes(p);
    } else if (s.isFile() && (s.mode & 0o600) !== 0o600) {
      try {
        chmodSync(p, (s.mode & 0o7777) | 0o600);
      } catch {
        // left as it is
      }
    }
  }
}

/** Remove a partial dir, read-only entries included. Throws when it cannot. */
function removePartial(partial: string): void {
  makeOwnerWritable(partial);
  rmSync(partial, { recursive: true, force: true });
}

export interface UnpackResult {
  archive: string; // absolute path of the archive
  target: string; // absolute path of the unpacked dir
  action: "unpacked" | "already_unpacked" | "tool_missing" | "failed";
  error?: string;
  /** Code page of the names (zip names that are not UTF-8, plain RAR4 names) and how it was chosen. */
  codePage?: CodePageChoice;
}

/**
 * Extraction argv for an archive, or null when no tool for it is on PATH.
 * Every tool runs non-interactively (stdin ignored, `-y` / `-o`) and gets a
 * password switch, so an encrypted archive fails at once ("Wrong password")
 * instead of prompting: without one, p7zip and unzip ask on /dev/tty and
 * hang a scan run from a terminal, and 7zz reads the password from stdin.
 * (unar needs none: it never prompts, see unarArgv.)
 * - zip: Info-ZIP unzip; `-P ""` gives it an (empty) password. (A zip
 *   with any non-ASCII name goes to 7-Zip instead, see zipSevenZipPlan.)
 * - 7z: 7-Zip. `7zz` (current 7-Zip) is preferred over `7z` (p7zip, frozen
 *   at 16.02/17.x), which lacks newer format revisions, e.g. RAR 7's
 *   compression algorithm version 1 ("Unsupported Method"). For both, `-p`
 *   with an empty value is a defined (empty) password and never prompts.
 * - rar: a solid RAR4 (`rar.solidRar4`, read only when unar is on PATH)
 *   goes to unar (`unar`, its path). Any other rar goes to bsdtar
 *   (libarchive; /usr/bin/bsdtar ships with macOS), else 7-Zip as for 7z.
 *   Homebrew's 7zz and p7zip have no RAR decompression: they extract stored
 *   members only. bsdtar decompresses RAR4 and RAR5 but has no RAR
 *   encryption support, so it never asks for a password (and the header
 *   check refuses encrypted archives before it runs). `rar.codePage` is the
 *   code page of plain non-ASCII RAR4 names (see rarheaders.ts), given to
 *   bsdtar and unar; 7-Zip cannot be given it and writes such names as
 *   private-use chars, so that archive fails the check after 7-Zip.
 *   unrar is not used: in a real-data run it hung past 60 s with stdin closed.
 */
function extractArgv(
  archiveExt: string, archive: string, outDir: string, rar: RarHeaders | null, unar: string | null,
): string[] | null {
  switch (archiveExt) {
    case "zip": {
      const unzip = Bun.which("unzip");
      return unzip === null ? null : [unzip, "-qq", "-o", "-P", "", archive, "-d", outDir];
    }
    case "rar": {
      const rarCodePage = rar?.codePage?.cp ?? null;
      if (rar?.solidRar4) return unar === null ? null : unarArgv(unar, archive, outDir, rarCodePage);
      const bsdtar = Bun.which("bsdtar");
      if (bsdtar !== null) return bsdtarArgv(bsdtar, archive, outDir, rarCodePage);
      const sevenZip = findSevenZip();
      return sevenZip === null ? null : sevenZipArgv(sevenZip, archive, outDir);
    }
    case "7z": {
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

/**
 * bsdtar for untrusted input. Without `-P` it already strips a leading `/`
 * and refuses `..` paths and writes through symlinks. The `--no-*` flags
 * keep owner, permission extras, ACLs, extended attributes, file flags
 * (libarchive maps RAR5 Windows attributes to fflags such as `hidden`) and
 * AppleDouble metadata from being restored, also when run as root.
 * `rar:hdrcharset` decodes plain OEM RAR4 names with the code page the
 * header check chose (libarchive 3.7.4 on macOS takes CP437, CP852, CP1252
 * and CP1250).
 */
const bsdtarArgv = (bin: string, archive: string, outDir: string, rarCodePage: CodePage | null): string[] => [
  bin, "-x", "-f", archive, "-C", outDir,
  "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-xattrs", "--no-fflags", "--no-mac-metadata",
  ...(rarCodePage === null ? [] : ["--options", `rar:hdrcharset=CP${rarCodePage}`]),
];

/** unar's `-e` name of each code page (unar 1.10.7 also takes cp1252 and cp1250). */
const UNAR_ENCODING: Record<CodePage, string> = { 437: "cp437", 852: "cp852", 1252: "windows-1252", 1250: "windows-1250" };

/**
 * unar (The Unarchiver's CLI, XADMaster) for a solid RAR4, which libarchive
 * cannot extract. Checked with unar 1.10.7:
 * - `-o <dir> -D`: into the partial dir, never inside an enclosing dir of
 *   its own, so the tree matches the header names;
 * - `-nr`: no recursion into an archive inside the archive (for rar it
 *   changes nothing: a member that is an archive is written as a file);
 * - `-k skip`: no resource forks, no `._` or `.rsrc` AppleDouble files;
 * - `-nq`: the archive's com.apple.quarantine xattr is not copied to every
 *   extracted file and dir, which it is by default;
 * - `-s`: a file that already exists is skipped, never renamed or asked
 *   about (without it, a case-only name clash was written as `NAME-1.txt`);
 *   the header check then reports the entry missing;
 * - `-q`: only failures are printed, and on stderr (without it everything,
 *   failures included, goes to stdout, which runTool discards), so the
 *   failure message names the file, e.g. "Failed! (Wrong checksum)";
 * - `-e <encoding>`: plain non-ASCII RAR4 names are decoded with the code
 *   page the header check chose; on its own unar guesses (cp1252 for
 *   Białowieża's cp852 bytes). What it writes for every defined byte of
 *   cp437, cp852, cp1252 and cp1250 equals the TS decode after NFC.
 *   Unicode-flagged names ignore `-e`.
 * - `--`: ends the options, so an archive path cannot be read as one.
 * unar exits 1 when a member fails its CRC32 (after writing it) and 2 for
 * an encrypted archive with no password ("This archive requires a password
 * to unpack"); it never prompts, under a terminal either. It does not write
 * through a symlink it extracted: a later entry under one fails ("Could not
 * create directory"), one at the same path is skipped.
 */
const unarArgv = (bin: string, archive: string, outDir: string, rarCodePage: CodePage | null): string[] => [
  bin, "-o", outDir, "-D", "-nr", "-k", "skip", "-nq", "-s", "-q",
  ...(rarCodePage === null ? [] : ["-e", UNAR_ENCODING[rarCodePage]]),
  "--", archive,
];

interface SevenZipZipPlan {
  sevenZip: string;
  /** Code-page names: 7-Zip extracts a copy with them decoded to UTF-8. */
  codePage: { cd: CentralDirectory; choice: CodePageChoice } | null;
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
 *   names are decoded here with the code page chooseCodePage picks (`prefer`
 *   orders its ties), into a copy of the zip that carries them as flagged
 *   UTF-8, and 7-Zip extracts that copy.
 * Returns null for a zip that goes to unzip: names all ASCII, or a central
 * directory zipnames.ts does not read (ZIP64, a split or damaged archive),
 * whose names are unknown. Returns an error when the names are not text in
 * any code page, or when 7-Zip is needed and none is on PATH.
 */
function zipSevenZipPlan(
  archivePath: string, prefer: readonly CodePage[],
): SevenZipZipPlan | { error: string; codePage?: CodePageChoice } | null {
  const cd = readCentralDirectory(archivePath);
  if (cd === null || !cd.entries.some((e) => e.name.some((b) => b >= 0x80))) return null;
  const sevenZip = findSevenZip();
  if (needsCodePage(cd)) {
    const choice = chooseCodePage(cd, archivePath, prefer);
    if (choice === null) return { error: undecodableNames(archivePath) };
    if (sevenZip === null)
      return { error: `zip names are cp${choice.cp}, not UTF-8: extracting them needs 7zz or 7z on PATH`, codePage: choice };
    return { sevenZip, codePage: { cd, choice } };
  }
  if (sevenZip === null) return { error: "zip names are non-ASCII UTF-8: extracting them needs 7zz or 7z on PATH" };
  return { sevenZip, codePage: null };
}

/**
 * The code page choice scan makes for an archive's names (zipSevenZipPlan,
 * readRarHeaders), made again from the archive alone; null when its names
 * need none (UTF-8 or ASCII names, a 7z), or when it cannot be read or is
 * refused. The resolver uses it to flag roots whose names were a guess.
 */
export function archiveNameCodePage(archivePath: string, prefer: readonly CodePage[]): CodePageChoice | null {
  const x = ext(archivePath);
  if (x === "zip") {
    const cd = readCentralDirectory(archivePath);
    return cd !== null && needsCodePage(cd) ? chooseCodePage(cd, archivePath, prefer) : null;
  }
  if (x === "rar") {
    // Solid RAR4 allowed: one that was unpacked went to unar.
    const r = readRarHeaders(archivePath, prefer, { solidRar4: true });
    return "error" in r ? null : r.codePage;
  }
  return null;
}

/** Hard limit on one unpack tool run. */
export const UNPACK_TIMEOUT_MS = 30 * 60 * 1000;

const formatDuration = (ms: number): string =>
  ms % 60_000 === 0 ? `${ms / 60_000} min` : ms % 1000 === 0 ? `${ms / 1000} s` : `${ms} ms`;

export interface UnpackOptions {
  /** Overrides UNPACK_TIMEOUT_MS (tests). */
  timeoutMs?: number;
  /** income.yaml `archive_code_pages`: the code pages that come first when a tie is broken by order. */
  codePages?: readonly CodePage[];
}

export async function unpackArchive(archivePath: string, dryRun: boolean, opts: UnpackOptions = {}): Promise<UnpackResult> {
  const x = ext(archivePath);
  const stem = archivePath.slice(0, -(x.length + 1));
  const target = stem + ".unpacked";
  const partial = stem + PARTIAL_UNPACK_SUFFIX;
  if (existsSync(target)) return { archive: archivePath, target, action: "already_unpacked" };
  const prefer = opts.codePages ?? [];
  const sevenZipZip = x === "zip" ? zipSevenZipPlan(archivePath, prefer) : null;
  if (sevenZipZip !== null && "error" in sevenZipZip) {
    const { error, codePage } = sevenZipZip;
    return { archive: archivePath, target, action: "failed", error, ...(codePage && { codePage }) };
  }
  // rar: headers read and checked before anything is written. A solid RAR4
  // is refused here unless unar is on PATH to extract it.
  let rar: RarHeaders | null = null;
  const unar = x === "rar" ? Bun.which("unar") : null;
  if (x === "rar") {
    const r = readRarHeaders(archivePath, prefer, { solidRar4: unar !== null });
    if ("error" in r) return { archive: archivePath, target, action: "failed", error: r.error };
    rar = r;
  }
  const choice = sevenZipZip?.codePage?.choice ?? rar?.codePage ?? null;
  const cpField = choice === null ? {} : { codePage: choice };
  const args = sevenZipZip === null ? extractArgv(x, archivePath, partial, rar, unar) : null;
  if (sevenZipZip === null && args === null)
    return { archive: archivePath, target, action: "tool_missing", error: `no tool for .${x}`, ...cpField };
  if (dryRun) return { archive: archivePath, target, action: "unpacked", ...cpField };

  const failed = (error: string): UnpackResult => {
    try {
      removePartial(partial);
    } catch {
      // left for the next scan, which removes it before retrying
    }
    return { archive: archivePath, target, action: "failed", error, ...cpField };
  };
  let copyDir: string | null = null; // temp dir of the UTF-8-named zip copy
  const timeoutMs = opts.timeoutMs ?? UNPACK_TIMEOUT_MS;
  // On a stop signal: the partial dir and the zip copy, as on any failure.
  const cleanupOnSignal = () => {
    removePartial(partial);
    if (copyDir !== null) rmSync(copyDir, { recursive: true, force: true });
  };
  try {
    // A leftover from a run that died mid-extraction (possibly read-only).
    removePartial(partial);
    mkdirSync(partial, { recursive: true });
    let argv: string[];
    if (sevenZipZip?.codePage) {
      const { cd, choice } = sevenZipZip.codePage;
      // Local temp dir, not the income volume: the copy is as large as the zip.
      copyDir = mkdtempSync(join(tmpdir(), "intake-zip-"));
      const copy = join(copyDir, "utf8-names.zip");
      writeUtf8NamedCopy(archivePath, copy, cd, choice.cp);
      argv = sevenZipArgv(sevenZipZip.sevenZip, copy, partial);
    } else if (sevenZipZip) {
      argv = sevenZipArgv(sevenZipZip.sevenZip, archivePath, partial);
    } else {
      argv = args!;
    }
    const run = await runTool(argv, timeoutMs, { cleanup: cleanupOnSignal });
    // Whatever the outcome: read-only modes from the archive would block the
    // removal of a failed tree and the tag writes on copies of a good one.
    makeOwnerWritable(partial);
    if (run.timedOut) return failed(`${basename(argv[0]!)} timed out after ${formatDuration(timeoutMs)}`);
    // Any non-zero exit is a failure, even when files appeared (7-Zip exits 1
    // or 2 after writing the members it could): the partial dir goes.
    if (run.code !== 0) return failed(run.stderr.trim().slice(0, 200) || `${argv[0]} exited ${run.code}`);
    stripSymlinks(partial);
    if (rar !== null) {
      const problem = await verifyRarExtraction(partial, rar);
      if (problem !== null) return failed(problem);
    }
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
  return { archive: archivePath, target, action: "unpacked", ...cpField };
}
