import { lstatSync, readdirSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export const AUDIO_EXTS = new Set([
  "flac", "mp3", "wav", "aiff", "aif", "m4a", "ogg", "ape", "wv", "dsf", "dff",
]);
export const ARCHIVE_EXTS = new Set(["zip", "rar", "7z"]);
export const LOSSLESS_EXTS = new Set(["flac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"]);

const JUNK_FILES = new Set([".ds_store", "thumbs.db", "desktop.ini"]);
const JUNK_DIRS = new Set(["@eadir", ".appledouble", "__macosx"]);

/** Files in flight for per-file I/O (tag snapshots, hashing, verification). */
export const IO_CONCURRENCY = 8;

/**
 * Map with bounded concurrency, preserving input order in the result. The
 * per-file loops (read tags, hash, verify a placed copy) awaited one file at a
 * time, which leaves the device queue empty on a release of any size. Order is
 * preserved so output — sidecars, goldens, error messages — is unaffected.
 *
 * If `fn` rejects, the returned promise rejects like the sequential loop did;
 * tasks already in flight still run to completion.
 */
export async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async (): Promise<void> => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]!, i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

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

const DISC_WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];

/**
 * Disc dir names, the one shared detector (resolver pass 2, bootstrap).
 * A disc prefix followed by an index:
 * - numeric (`CD1`, `cd 2`, `disk-2`, `Disc 07`), optionally followed by a disc
 *   title after whitespace, a dash or a bracket (`CD1 - Disc Title`,
 *   `CD1 Disc Title`, `Disc 2 - X`, `CD1 (Live)`);
 * - a single letter after a separator (`Side A`, `LP_B`), no title;
 * - a spelled-out number one..ten (`Disc One`), no title.
 * Any other word after the prefix does not match ("Disk Jockey", "Side
 * Projects", "Discography", "CDs").
 */
export const DISC_DIR_RE = new RegExp(
  "^(?:cd|disc|disk|vinyl|side|lp)" +
    "(?:[\\s_-]*0*(\\d{1,3})(?:[\\s_]*[-–—:.(\\[][\\s_]*\\S.*|[\\s_]+\\S.*)?" +
    "|[\\s_-]+[a-z]" +
    `|[\\s_-]+(${DISC_WORDS.join("|")}))$`,
  "i",
);

export function discNumberFromDirName(name: string): number | null {
  const m = name.match(DISC_DIR_RE);
  if (!m) return null;
  if (m[1] !== undefined) return parseInt(m[1], 10);
  if (m[2] !== undefined) return DISC_WORDS.indexOf(m[2].toLowerCase()) + 1;
  return null; // letter index (Side A): no number
}

/**
 * Disc encoded in the track number (101..1nn, 201..2nn, …), as some web
 * stores number multi-disc sets: disc = floor(n/100), track = n mod 100.
 * Applies only when the whole set agrees: every file has a track number, each
 * is >= 101 and not a multiple of 100, and the hundreds present are 1..k with
 * no gap. Returns one position per input, or null when the rule does not
 * apply (track numbers are then plain). The caller checks that no file has a
 * disc tag.
 */
export function decodeDiscInTrack(tracks: (number | null)[]): { disc: number; track: number }[] | null {
  if (tracks.length === 0) return null;
  const out: { disc: number; track: number }[] = [];
  const discs = new Set<number>();
  for (const n of tracks) {
    if (n == null || !Number.isInteger(n) || n < 101 || n % 100 === 0) return null;
    const disc = Math.floor(n / 100);
    discs.add(disc);
    out.push({ disc, track: n % 100 });
  }
  return discs.size === Math.max(...discs) ? out : null; // min is >= 1, so this means 1..k
}

/** The `cluster.albumartist` the resolver gives a Various Artists release (doc 01). */
export const VARIOUS_ARTISTS = "Various Artists";

/** Artist values that stand for a Various Artists compilation: Various Artists, Various, VA, V.A., V/A. */
export function isVariousArtists(name: string | null): boolean {
  const k = normKey(name).replace(/[\s./]/g, "");
  return k === "variousartists" || k === "various" || k === "va";
}

// "VA" is uppercase only so real names like "Va Va Voom" stay artists; a bare
// "Various " prefix is not VA either ("Various Production" is an artist).
const VA_PREFIX_CASED_RE = /^VA\s/;
const VA_PREFIX_ANYCASE_RE = /^(?:v\.a\.?|v\/a|various\s+artists)\s/i;

/**
 * A name that starts with a Various Artists token followed by whitespace:
 * scene leftovers such as an artist parsed as "VA  Title (2013) FLAC". Tokens:
 * VA (uppercase), V.A., V.A, V/A, Various Artists (any case).
 */
export function hasVariousArtistsPrefix(name: string | null): boolean {
  if (name == null) return false;
  const s = name.trimStart();
  return VA_PREFIX_CASED_RE.test(s) || VA_PREFIX_ANYCASE_RE.test(s);
}

// Matched on normKey(name); [^a-z0-9]* stands for any spaces or punctuation.
const SELF_RELEASED_RE = /^[^a-z0-9]*self[^a-z0-9]*releas(?:e|ed|es)[^a-z0-9]*$/;
const NO_LABEL_RE = /^[^a-z0-9]*no[^a-z0-9]*label[^a-z0-9]*$/;
const NOT_ON_LABEL_RE = /^[^a-z0-9]*not[^a-z0-9]*on[^a-z0-9]*label(?![a-z0-9])/;

/**
 * A label credit that names no label: a self-released spelling (Self-Released,
 * self released, Self Release, Self-Releases, SelfReleased; the whole value, any case and
 * separators), "No Label" (the whole value), or anything starting with "Not On
 * Label", as Discogs writes it ("Not On Label (Some Artist Self-released)").
 * Placeholders like "none" or "unknown" are not matched.
 */
export function isNoLabel(name: string | null): boolean {
  const k = normKey(name);
  if (k === "") return false;
  return SELF_RELEASED_RE.test(k) || NO_LABEL_RE.test(k) || NOT_ON_LABEL_RE.test(k);
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
