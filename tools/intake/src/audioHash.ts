// audio_hash per docs/intake/intake-03-contract-spec.md (normative).
// Tag edits must not change the hash for flac/mp3/wav/aiff.

import { basename, resolve } from "node:path";
import { ext } from "./util.ts";

export interface HashResult {
  hash: string;
  issues: string[]; // e.g. flac_md5_unset
}

/**
 * Issues of an unset-MD5 FLAC that could not be decoded and is keyed by the
 * `fsha1:` fallback (doc 03): the root gets needs_review.
 */
const FLAC_FALLBACK_ISSUES: readonly string[] = ["flac_decoder_missing", "flac_decode_failed"];

export function isFlacFallbackIssue(issue: string): boolean {
  return FLAC_FALLBACK_ISSUES.includes(issue);
}

function sha1Of(buf: Uint8Array): string {
  const h = new Bun.CryptoHasher("sha1");
  h.update(buf);
  return h.digest("hex");
}

/** Whole-file SHA1, streamed: the file is never held in memory at once. */
async function sha1File(path: string): Promise<string> {
  const h = new Bun.CryptoHasher("sha1");
  for await (const chunk of Bun.file(path).stream()) h.update(chunk);
  return h.digest("hex");
}

function readU32SyncSafe(b: Uint8Array, off: number): number {
  return ((b[off]! & 0x7f) << 21) | ((b[off + 1]! & 0x7f) << 14) | ((b[off + 2]! & 0x7f) << 7) | (b[off + 3]! & 0x7f);
}

function readU32LE(b: Uint8Array, off: number): number {
  return b[off]! | (b[off + 1]! << 8) | (b[off + 2]! << 16) | (b[off + 3]! << 24);
}

function readU32BE(b: Uint8Array, off: number): number {
  return (b[off]! << 24) | (b[off + 1]! << 16) | (b[off + 2]! << 8) | b[off + 3]!;
}

function ascii(b: Uint8Array, off: number, len: number): string {
  const end = Math.min(off + len, b.length);
  let s = "";
  for (let i = off; i < end; i++) s += String.fromCharCode(b[i]!);
  return s;
}

/** Skip ID3v2 block(s) at the head; returns offset of first non-ID3 byte. */
function skipId3v2(b: Uint8Array): number {
  let off = 0;
  while (off + 10 <= b.length && ascii(b, off, 3) === "ID3") {
    const flags = b[off + 5]!;
    const size = readU32SyncSafe(b, off + 6);
    off += 10 + size + (flags & 0x10 ? 10 : 0); // footer flag adds 10
  }
  return off;
}

type StreamInfo =
  | { kind: "md5"; md5: string } // STREAMINFO MD5 set
  | { kind: "unset" } // STREAMINFO MD5 all zeros
  | { kind: "invalid"; issue: "flac_bad_magic" | "flac_no_streaminfo" };

/** Read the STREAMINFO MD5 of a FLAC (or the head of one). */
function flacStreamInfo(b: Uint8Array): StreamInfo {
  let off = skipId3v2(b);
  if (ascii(b, off, 4) !== "fLaC") return { kind: "invalid", issue: "flac_bad_magic" };
  off += 4;
  while (off + 4 <= b.length) {
    const header = b[off]!;
    const type = header & 0x7f;
    const len = (b[off + 1]! << 16) | (b[off + 2]! << 8) | b[off + 3]!;
    off += 4;
    if (type === 0) {
      // STREAMINFO is 34 bytes; MD5 is the trailing 16.
      const md5 = b.subarray(off + 18, off + 34);
      const hex = Array.from(md5, (x) => x.toString(16).padStart(2, "0")).join("");
      return hex === "0".repeat(32) ? { kind: "unset" } : { kind: "md5", md5: hex };
    }
    if (header & 0x80) break; // last block and no STREAMINFO seen
    off += len;
  }
  return { kind: "invalid", issue: "flac_no_streaminfo" };
}

// Decode to exactly what a correctly set STREAMINFO MD5 covers: interleaved
// samples, little-endian, signed, whole bytes per sample (doc 03).
const FLAC_DECODE_ARGS = ["-d", "-c", "-s", "--force-raw-format", "--endian=little", "--sign=signed"];

type Decoded = { md5: string } | { issue: "flac_decoder_missing" | "flac_decode_failed" };

/**
 * MD5 of the decoded audio of a FLAC file (path) or buffer (fed on stdin).
 * The decoder's stdout is streamed into the hasher, never buffered whole.
 * `flac` is located on PATH like `metaflac` (provenance.ts).
 */
async function flacDecodedMd5(src: string | Uint8Array): Promise<Decoded> {
  const flac = Bun.which("flac");
  if (flac === null) return { issue: "flac_decoder_missing" };
  let proc;
  try {
    proc = Bun.spawn([flac, ...FLAC_DECODE_ARGS, typeof src === "string" ? resolve(src) : "-"], {
      stdin: typeof src === "string" ? "ignore" : src,
      stdout: "pipe",
      stderr: "ignore",
    });
  } catch {
    return { issue: "flac_decoder_missing" }; // found on PATH but cannot be started
  }
  try {
    const h = new Bun.CryptoHasher("md5");
    for await (const chunk of proc.stdout) h.update(chunk);
    // Non-zero exit: CRC mismatch, lost sync, truncation (sample count short).
    if ((await proc.exited) !== 0) return { issue: "flac_decode_failed" };
    return { md5: h.digest("hex") };
  } catch {
    proc.kill();
    return { issue: "flac_decode_failed" };
  }
}

/**
 * Unset STREAMINFO MD5: key by the MD5 of the decoded audio, the value a
 * correct STREAMINFO would hold, so tag writes and a later repair keep the
 * key. Without a usable decoder: whole-file SHA1 fallback (doc 03).
 */
async function flacUnsetMd5Hash(src: string | Uint8Array, wholeFileSha1: () => Promise<string>): Promise<HashResult> {
  const d = await flacDecodedMd5(src);
  if ("md5" in d) return { hash: "flacmd5:" + d.md5, issues: ["flac_md5_unset"] };
  return { hash: "fsha1:" + (await wholeFileSha1()), issues: ["flac_md5_unset", d.issue] };
}

/** FLAC: "flacmd5:" + STREAMINFO MD5 (embedded, or computed when unset). */
async function flacHash(b: Uint8Array): Promise<HashResult> {
  const info = flacStreamInfo(b);
  if (info.kind === "md5") return { hash: "flacmd5:" + info.md5, issues: [] };
  if (info.kind === "unset") return flacUnsetMd5Hash(b, async () => sha1Of(b));
  return { hash: "fsha1:" + sha1Of(b), issues: [info.issue] };
}

/** MP3: SHA1 of bytes minus ID3v2 head block(s), minus ID3v1/APEv2 tail. */
function mp3Hash(b: Uint8Array): HashResult {
  const start = skipId3v2(b);
  let end = b.length;
  if (end - start >= 128 && ascii(b, end - 128, 3) === "TAG") end -= 128;
  // APEv2 footer: 32 bytes ending the tag; size at offset 12 covers items+footer.
  if (end - start >= 32 && ascii(b, end - 32, 8) === "APETAGEX") {
    const size = readU32LE(b, end - 32 + 12);
    const flags = readU32LE(b, end - 32 + 20);
    const total = size + (flags & 0x80000000 ? 32 : 0); // header-present flag
    if (total > 0 && total <= end - start) end -= total;
  }
  return { hash: "mp3sha1:" + sha1Of(b.subarray(start, end)), issues: [] };
}

/** RIFF/WAVE: SHA1 of the `data` chunk payload. */
function wavHash(b: Uint8Array): HashResult {
  if (ascii(b, 0, 4) !== "RIFF" || ascii(b, 8, 4) !== "WAVE")
    return { hash: "fsha1:" + sha1Of(b), issues: ["wav_bad_magic"] };
  let off = 12;
  while (off + 8 <= b.length) {
    const id = ascii(b, off, 4);
    const size = readU32LE(b, off + 4) >>> 0;
    if (id === "data") return { hash: "pcmsha1:" + sha1Of(b.subarray(off + 8, off + 8 + size)), issues: [] };
    off += 8 + size + (size & 1);
  }
  return { hash: "fsha1:" + sha1Of(b), issues: ["wav_no_data_chunk"] };
}

/** AIFF: SHA1 of the SSND chunk payload. */
function aiffHash(b: Uint8Array): HashResult {
  if (ascii(b, 0, 4) !== "FORM" || !["AIFF", "AIFC"].includes(ascii(b, 8, 4)))
    return { hash: "fsha1:" + sha1Of(b), issues: ["aiff_bad_magic"] };
  let off = 12;
  while (off + 8 <= b.length) {
    const id = ascii(b, off, 4);
    const size = readU32BE(b, off + 4) >>> 0;
    if (id === "SSND") return { hash: "pcmsha1:" + sha1Of(b.subarray(off + 8, off + 8 + size)), issues: [] };
    off += 8 + size + (size & 1);
  }
  return { hash: "fsha1:" + sha1Of(b), issues: ["aiff_no_ssnd_chunk"] };
}

/** DSF: SHA1 of the `data` chunk payload (chunk size includes its 12-byte header). */
function dsfHash(b: Uint8Array): HashResult {
  if (ascii(b, 0, 4) !== "DSD ") return { hash: "fsha1:" + sha1Of(b), issues: ["dsf_bad_magic"] };
  let off = 28; // DSD chunk is fixed 28 bytes
  while (off + 12 <= b.length) {
    const id = ascii(b, off, 4);
    // 64-bit LE size; high half assumed 0 for our purposes beyond 4 GiB safety
    const size = (readU32LE(b, off + 4) >>> 0) + (readU32LE(b, off + 8) >>> 0) * 2 ** 32;
    if (id === "data") return { hash: "pcmsha1:" + sha1Of(b.subarray(off + 12, off + size)), issues: [] };
    if (size < 12) break; // malformed chunk size cannot advance; fall back to whole-file hash
    off += size;
  }
  return { hash: "fsha1:" + sha1Of(b), issues: ["dsf_no_data_chunk"] };
}

export async function audioHashBuffer(name: string, b: Uint8Array): Promise<HashResult> {
  switch (ext(name)) {
    case "flac": return flacHash(b);
    case "mp3": return mp3Hash(b);
    case "wav": return wavHash(b);
    case "aiff":
    case "aif": return aiffHash(b);
    case "dsf": return dsfHash(b);
    default: return { hash: "fsha1:" + sha1Of(b), issues: [] };
  }
}

// STREAMINFO is always FLAC's first metadata block, right after the "fLaC"
// magic (plus any leading ID3v2). 1 MiB covers it even with an embedded tag /
// cover art, so the common flac path never reads the whole (multi-GB) file.
const FLAC_PREFIX = 1 << 20;

export async function audioHash(path: string): Promise<HashResult> {
  const file = Bun.file(path);
  if (ext(basename(path)) === "flac") {
    const info = flacStreamInfo(new Uint8Array(await file.slice(0, FLAC_PREFIX).arrayBuffer()));
    // A set STREAMINFO MD5 is independent of the rest of the file, so it is
    // byte-identical to the full-file result.
    if (info.kind === "md5") return { hash: "flacmd5:" + info.md5, issues: [] };
    // So is an unset one: the bytes up to STREAMINFO are the same in the full
    // file. The decoder reads the file itself and its output is streamed into
    // the hasher, as is the fsha1 fallback, so neither loads the whole file.
    if (info.kind === "unset") return flacUnsetMd5Hash(path, () => sha1File(path));
    // Bad magic / no STREAMINFO may be an artifact of the 1 MiB cut: re-read.
  }
  const buf = new Uint8Array(await file.arrayBuffer());
  return audioHashBuffer(basename(path), buf);
}

/**
 * Re-hash a file to check it against its recorded key `expected` (execute
 * verify, `--resume`, gc re-verify). A whole-file key (`fsha1:`) is checked as
 * a whole-file SHA1 whatever the format: an unset-MD5 FLAC keyed by the
 * fallback while `flac` was missing still verifies after `flac` is installed
 * (audioHash would now give its `flacmd5:` key). No tags are written to such a
 * file, so byte identity holds; for every other `fsha1:` file the two agree.
 */
export async function audioHashAs(path: string, expected: string): Promise<HashResult> {
  if (expected.startsWith("fsha1:")) return { hash: "fsha1:" + (await sha1File(path)), issues: [] };
  return audioHash(path);
}
