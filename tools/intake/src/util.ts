import { lstatSync, readdirSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export const AUDIO_EXTS = new Set([
  "flac", "mp3", "wav", "aiff", "aif", "m4a", "ogg", "ape", "wv", "dsf", "dff",
]);
export const ARCHIVE_EXTS = new Set(["zip", "rar", "7z"]);
export const LOSSLESS_EXTS = new Set(["flac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"]);

const JUNK_FILES = new Set([".ds_store", "thumbs.db", "desktop.ini"]);
const JUNK_DIRS = new Set(["@eadir", ".appledouble", "__macosx"]);

export function isJunkFile(name: string): boolean {
  const lower = name.toLowerCase();
  return JUNK_FILES.has(lower) || name.startsWith("._");
}

export function isJunkDir(name: string): boolean {
  return JUNK_DIRS.has(name.toLowerCase());
}

export function isSidecarName(name: string): boolean {
  return name === ".intake.json" || /^\.intake\.[a-z0-9_]+\.json$/i.test(name);
}

/**
 * A sidecar-relative file path is safe iff it stays within the release root:
 * non-empty, not absolute, no backslash or NUL, and no `.`/`..`/empty segment.
 * Income is an untrusted landing zone, so a re-read sidecar's `files[].path`
 * and any relative path derived from one must pass this before it reaches a
 * filesystem sink (copy/delete/rename).
 */
export function isSafeRelPath(p: string): boolean {
  if (!p || p.includes("\u0000") || p.includes("\\") || isAbsolute(p)) return false;
  return p.split("/").every((s) => s !== "" && s !== "." && s !== "..");
}

export function ext(name: string): string {
  const i = name.lastIndexOf(".");
  return i < 0 ? "" : name.slice(i + 1).toLowerCase();
}

export function isAudioFile(name: string): boolean {
  return !isJunkFile(name) && AUDIO_EXTS.has(ext(name));
}

export interface DirEntry {
  path: string; // absolute
  name: string;
  audioFiles: string[]; // names of direct audio files
  otherFiles: string[]; // names of direct non-audio, non-junk files
  subdirs: string[]; // names of non-junk subdirectories
}

/** Depth-first walk; returns entries bottom-up (children before parents). */
export function walkDirs(root: string): DirEntry[] {
  const out: DirEntry[] = [];
  const visit = (dir: string, name: string) => {
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      return;
    }
    const entry: DirEntry = { path: dir, name, audioFiles: [], otherFiles: [], subdirs: [] };
    for (const n of names.sort()) {
      const p = join(dir, n);
      let st;
      try {
        st = lstatSync(p);
      } catch {
        continue;
      }
      if (st.isSymbolicLink()) continue; // never follow symlinks (traversal / recursion-cycle guard)
      if (st.isDirectory()) {
        if (isJunkDir(n)) continue;
        entry.subdirs.push(n);
        visit(p, n);
      } else {
        if (isJunkFile(n) || isSidecarName(n)) continue;
        if (isAudioFile(n)) entry.audioFiles.push(n);
        else entry.otherFiles.push(n);
      }
    }
    out.push(entry);
  };
  visit(root, root.split("/").filter(Boolean).pop() ?? root);
  return out;
}

/** Normalization for cluster keys: casefold, strip diacritics, collapse ws. */
export function normKey(s: string | null): string {
  if (s == null) return "";
  return s
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

const DISC_SUFFIX = /[\s\-_]*[([]?(?:cd|disc|disk|vinyl|side|lp)[\s\-_]*[a-z0-9]+[)\]]?$/i;

/** Album normalization additionally strips a trailing disc suffix. */
export function normAlbum(s: string | null): string {
  if (s == null) return "";
  return normKey(s.replace(DISC_SUFFIX, ""));
}

export const DISC_DIR_RE = /^(cd|disc|disk|vinyl|side|lp)\s*[-_ ]?\w+$/i;

export function discNumberFromDirName(name: string): number | null {
  const m = name.match(/^(?:cd|disc|disk|vinyl|side|lp)\s*[-_ ]?0*(\d+)$/i);
  return m ? parseInt(m[1]!, 10) : null;
}

export function sha1Hex(data: Uint8Array | string): string {
  const h = new Bun.CryptoHasher("sha1");
  h.update(data);
  return h.digest("hex");
}

/** Deterministic sidecar id from stable inputs. */
export function makeId(seed: string): string {
  return "itk_" + sha1Hex(seed).slice(0, 8);
}

/** ISO 8601 with local timezone offset, e.g. 2026-07-11T14:30:00+02:00 */
export function isoLocal(d: Date = new Date()): string {
  const pad = (n: number, w = 2) => String(Math.abs(n)).padStart(w, "0");
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  const abs = Math.abs(off); // compute h:m from magnitude so negative half-hour zones are correct
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(Math.trunc(abs / 60))}:${pad(abs % 60)}`
  );
}

export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
