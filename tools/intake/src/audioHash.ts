// audio_hash per docs/intake/intake-03-contract-spec.md (normative).
// Tag edits must not change the hash for flac/mp3/wav/aiff.

import { basename } from "node:path";
import { ext } from "./util.ts";

export interface HashResult {
  hash: string;
  issues: string[]; // e.g. flac_md5_unset
}

function sha1Of(buf: Uint8Array): string {
  const h = new Bun.CryptoHasher("sha1");
  h.update(buf);
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
  return String.fromCharCode(...b.subarray(off, off + len));
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

/** FLAC: "flacmd5:" + embedded STREAMINFO MD5. */
function flacHash(b: Uint8Array): HashResult {
  let off = skipId3v2(b);
  if (ascii(b, off, 4) !== "fLaC") return { hash: "fsha1:" + sha1Of(b), issues: ["flac_bad_magic"] };
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
      if (hex === "0".repeat(32)) return { hash: "fsha1:" + sha1Of(b), issues: ["flac_md5_unset"] };
      return { hash: "flacmd5:" + hex, issues: [] };
    }
    if (header & 0x80) break; // last block and no STREAMINFO seen
    off += len;
  }
  return { hash: "fsha1:" + sha1Of(b), issues: ["flac_no_streaminfo"] };
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
    const size = readU32LE(b, off + 4);
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
    const size = readU32BE(b, off + 4);
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
    const size = readU32LE(b, off + 4) + readU32LE(b, off + 8) * 2 ** 32;
    if (id === "data") return { hash: "pcmsha1:" + sha1Of(b.subarray(off + 12, off + size)), issues: [] };
    off += size;
  }
  return { hash: "fsha1:" + sha1Of(b), issues: ["dsf_no_data_chunk"] };
}

export function audioHashBuffer(name: string, b: Uint8Array): HashResult {
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

export async function audioHash(path: string): Promise<HashResult> {
  const buf = new Uint8Array(await Bun.file(path).arrayBuffer());
  return audioHashBuffer(basename(path), buf);
}
