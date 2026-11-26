// Provenance tags at execute (doc 03): INTAKE_DATE, INTAKE_SOURCE,
// INTAKE_BATCH written to the COPIES only, via TXXX (mp3) / VorbisComment
// (flac). Writers must not change audio_hash: metaflac edits only metadata
// blocks (STREAMINFO MD5 untouched); for mp3 the frames go into the ID3v2 tag
// at the head, which mp3sha1 skips, and the bytes after it stay identical. A
// FLAC keyed by the `fsha1:` fallback (whole-file SHA1) gets no tags, since
// any tag write changes that key. Other formats are skipped with an issue. A
// skip is reported as `provenance_tags_skipped:<why>`; any other issue
// (metaflac_missing, metaflac_failed, provenance_write_failed) is a failed
// write, which fails the root at execute.
//
// MP3 (mp3MergeTags) keeps ONE ID3v2 tag at the head. A second tag in front
// of the original one hides it from readers that stop after the first tag
// (mutagen, so beets): no title, artist or album.
// - No ID3v2 tag at offset 0: a new ID3v2.3 tag holding the three TXXX
//   frames, no padding, then the file unchanged.
// - One ID3v2.3 or ID3v2.4 tag: every frame copied verbatim except TXXX
//   frames described INTAKE_DATE/INTAKE_SOURCE/INTAKE_BATCH, which are
//   replaced (a re-run never duplicates them); the new TXXX frames are
//   appended in the tag's version. Version, revision and header flags are
//   kept. Padding: the tag keeps its size when the frames fit in its old
//   frames and padding, else it grows to fit with none. A v2.4 footer is
//   rebuilt, with no padding (the spec forbids both).
// - Anything else is refused with the file untouched, as
//   `provenance_write_failed: <reason>`: ID3v2.2 or any version but 3 and 4,
//   unsynchronisation, an extended header, unknown header flags, a second tag
//   right after the first, a frame walk that does not parse (bad ID, size past
//   the tag end, a v2.4 size that is not syncsafe as iTunes wrote them),
//   non-zero bytes in the padding, a footer that does not match. Never stack,
//   never guess.

import { readFileSync, writeFileSync } from "node:fs";
import { ext } from "./util.ts";

export interface ProvenanceTags {
  INTAKE_DATE: string;
  INTAKE_SOURCE: string;
  INTAKE_BATCH: string;
}

export interface TagWriteResult {
  written: boolean;
  issue: string | null;
}

async function metaflacSetTags(path: string, tags: ProvenanceTags): Promise<TagWriteResult> {
  if (Bun.which("metaflac") === null) return { written: false, issue: "metaflac_missing" };
  const args = ["metaflac"];
  for (const [k, v] of Object.entries(tags)) args.push(`--remove-tag=${k}`, `--set-tag=${k}=${v}`);
  args.push(path);
  const proc = Bun.spawn(args, { stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) {
    const err = (await new Response(proc.stderr).text()).trim().slice(0, 120);
    return { written: false, issue: `metaflac_failed: ${err}` };
  }
  return { written: true, issue: null };
}

const INTAKE_KEYS: ReadonlySet<string> = new Set(["INTAKE_DATE", "INTAKE_SOURCE", "INTAKE_BATCH"]);
const SYNCSAFE_MAX = 0x0fffffff; // largest 28-bit syncsafe size

function syncSafe(n: number): number[] {
  return [(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f];
}

function u32be(n: number): number[] {
  return [(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
}

/** A syncsafe 32-bit integer, or null when a byte has its high bit set. */
function readSyncSafe(b: Uint8Array, off: number): number | null {
  let n = 0;
  for (let i = 0; i < 4; i++) {
    const x = b[off + i]!;
    if (x & 0x80) return null;
    n = (n << 7) | x;
  }
  return n;
}

function readU32BE(b: Uint8Array, off: number): number {
  return ((b[off]! << 24) | (b[off + 1]! << 16) | (b[off + 2]! << 8) | b[off + 3]!) >>> 0;
}

function ascii(b: Uint8Array, off: number, len: number): string {
  let s = "";
  for (let i = off; i < Math.min(off + len, b.length); i++) s += String.fromCharCode(b[i]!);
  return s;
}

/** UTF-16 code units as a string; `le` picks the byte order. */
function utf16(b: Uint8Array, le: boolean): string {
  let s = "";
  for (let i = 0; i + 1 < b.length; i += 2) s += String.fromCharCode(le ? b[i]! | (b[i + 1]! << 8) : (b[i]! << 8) | b[i + 1]!);
  return s;
}

/**
 * The terminated string at the start of `b` in ID3v2 text encoding `enc`:
 * 0 Latin-1 and 3 UTF-8 end at 0x00; 1 UTF-16 with BOM and 2 UTF-16BE end
 * at 0x0000 on a code-unit boundary. Null when it cannot be decoded (an
 * unknown encoding, UTF-16 with no BOM).
 */
function decodeTerminated(b: Uint8Array, enc: number): string | null {
  if (enc === 0 || enc === 3) {
    const nul = b.indexOf(0);
    const text = nul < 0 ? b : b.subarray(0, nul);
    return enc === 0 ? ascii(text, 0, text.length) : new TextDecoder().decode(text);
  }
  if (enc !== 1 && enc !== 2) return null;
  let end = b.length - (b.length % 2);
  for (let i = 0; i + 1 < b.length; i += 2) {
    if (b[i] === 0 && b[i + 1] === 0) {
      end = i;
      break;
    }
  }
  const units = b.subarray(0, end);
  if (enc === 2) return utf16(units, false);
  if (units.length === 0) return "";
  if (units[0] === 0xff && units[1] === 0xfe) return utf16(units.subarray(2), true);
  if (units[0] === 0xfe && units[1] === 0xff) return utf16(units.subarray(2), false);
  return null;
}

/**
 * A TXXX frame (header included) whose description is an INTAKE_* key. Only
 * a frame with no format flags is read: a compressed, encrypted, grouped or
 * unsynchronised one is not intake's (it writes none) and is kept as it is.
 */
function isIntakeTxxx(frame: Uint8Array): boolean {
  if (ascii(frame, 0, 4) !== "TXXX" || frame[9] !== 0 || frame.length < 11) return false;
  const description = decodeTerminated(frame.subarray(11), frame[10]!);
  return description !== null && INTAKE_KEYS.has(description);
}

/** `s` in ID3v2 text encoding 0 (Latin-1), 1 (UTF-16LE with BOM) or 3 (UTF-8). */
function encodeText(s: string, enc: 0 | 1 | 3): number[] {
  if (enc === 3) return [...new TextEncoder().encode(s)];
  const out: number[] = enc === 1 ? [0xff, 0xfe] : [];
  for (let i = 0; i < s.length; i++) {
    const unit = s.charCodeAt(i);
    if (enc === 1) out.push(unit & 0xff, unit >> 8);
    else out.push(unit);
  }
  return out;
}

/**
 * One TXXX frame in ID3v2.`version`: Latin-1 when every char is at most
 * U+00FF, else UTF-16 with BOM (v2.3) or UTF-8 (v2.4). The frame size is a
 * plain 32-bit integer in v2.3, syncsafe in v2.4.
 */
function txxxFrame(version: 3 | 4, description: string, value: string): Uint8Array {
  const enc = /^[\u0000-ÿ]*$/.test(description + value) ? 0 : version === 3 ? 1 : 3;
  const body = [enc, ...encodeText(description, enc), ...(enc === 1 ? [0, 0] : [0]), ...encodeText(value, enc)];
  const size = version === 3 ? u32be(body.length) : syncSafe(body.length);
  return new Uint8Array([0x54, 0x58, 0x58, 0x58, ...size, 0, 0, ...body]);
}

type HeadTag =
  | { kind: "none" }
  | { kind: "refused"; reason: string }
  | {
      kind: "tag";
      version: 3 | 4;
      revision: number;
      flags: number;
      footer: boolean;
      size: number; // frames + padding, as in the header
      end: number; // first byte after the tag (footer included)
      frames: Uint8Array[]; // kept verbatim, INTAKE_* TXXX dropped
    };

const refused = (reason: string): HeadTag => ({ kind: "refused", reason });

/** The ID3v2 tag at offset 0 of an mp3, if it is one mp3MergeTags can rebuild. */
function parseHeadTag(b: Uint8Array): HeadTag {
  if (ascii(b, 0, 3) !== "ID3") return { kind: "none" };
  if (b.length < 10) return refused("truncated ID3v2 header");
  const version = b[3]!;
  const revision = b[4]!;
  const flags = b[5]!;
  if (version !== 3 && version !== 4) return refused(`ID3v2.${version} tag (only ID3v2.3 and ID3v2.4 are merged)`);
  if (flags & 0x80) return refused("ID3v2 unsynchronisation flag set");
  if (flags & 0x40) return refused("ID3v2 extended header");
  const unknown = flags & (version === 3 ? 0x1f : 0x0f);
  if (unknown) return refused(`unknown ID3v2.${version} header flags 0x${unknown.toString(16)}`);
  const size = readSyncSafe(b, 6);
  if (size === null) return refused("ID3v2 tag size is not syncsafe");
  const footer = (flags & 0x10) !== 0; // v2.4 only: 0x10 is an unknown flag in v2.3
  const end = 10 + size + (footer ? 10 : 0);
  if (end > b.length) return refused("ID3v2 tag runs past the end of the file");
  if (footer) {
    const f = 10 + size;
    if (ascii(b, f, 3) !== "3DI" || b[f + 3] !== version || b[f + 4] !== revision || b[f + 5] !== flags || readSyncSafe(b, f + 6) !== size)
      return refused("ID3v2.4 footer does not match the header");
  }
  if (ascii(b, end, 3) === "ID3") return refused("more than one ID3v2 tag at the head");

  const frames: Uint8Array[] = [];
  const limit = 10 + size;
  let off = 10;
  while (off < limit) {
    if (b[off] === 0) {
      // Padding: zeros to the tag end. Anything else means the walk is off.
      for (let i = off; i < limit; i++) if (b[i] !== 0) return refused(`non-zero byte in the ID3v2 padding at byte ${i}`);
      break;
    }
    if (off + 10 > limit) return refused(`ID3v2 frame header at byte ${off} runs past the tag end`);
    const id = ascii(b, off, 4);
    if (!/^[A-Z0-9]{4}$/.test(id)) return refused(`bad ID3v2 frame ID at byte ${off}`);
    const frameSize = version === 3 ? readU32BE(b, off + 4) : readSyncSafe(b, off + 4);
    if (frameSize === null) return refused(`ID3v2.4 frame ${id} at byte ${off}: size is not syncsafe`);
    if (off + 10 + frameSize > limit) return refused(`ID3v2 frame ${id} at byte ${off} runs past the tag end`);
    const frame = b.subarray(off, off + 10 + frameSize);
    if (!isIntakeTxxx(frame)) frames.push(frame);
    off += 10 + frameSize;
  }
  return { kind: "tag", version, revision, flags, footer, size, end, frames };
}

/**
 * Merge the TXXX provenance frames into the mp3's ID3v2 tag (see the file
 * header): a new ID3v2.3 tag when there is none, the existing v2.3/v2.4 tag
 * rebuilt otherwise, the bytes after it unchanged. Refused, the file
 * untouched, when the tag cannot be rebuilt safely.
 */
function mp3MergeTags(path: string, tags: ProvenanceTags): TagWriteResult {
  const original: Uint8Array = readFileSync(path);
  const head = parseHeadTag(original);
  if (head.kind === "refused") return { written: false, issue: `provenance_write_failed: ${head.reason}` };
  const tag = head.kind === "tag" ? head : null;
  const version = tag?.version ?? 3;
  const frames = [...(tag?.frames ?? []), ...Object.entries(tags).map(([k, v]) => txxxFrame(version, k, v))];
  const framesLength = frames.reduce((n, f) => n + f.length, 0);
  // Padding: the tag keeps its size when the frames fit in its old frames and
  // padding, else it grows to fit with none; never any with a footer (spec).
  const size = tag && !tag.footer && framesLength <= tag.size ? tag.size : framesLength;
  if (size > SYNCSAFE_MAX) return { written: false, issue: "provenance_write_failed: ID3v2 tag would be too large" };
  const footer = tag?.footer ?? false;
  const header = [version, tag?.revision ?? 0, tag?.flags ?? 0, ...syncSafe(size)];
  const audio = original.subarray(tag?.end ?? 0);
  const tagEnd = 10 + size + (footer ? 10 : 0);
  const out = new Uint8Array(tagEnd + audio.length); // zero-filled: the padding
  out.set([0x49, 0x44, 0x33, ...header], 0); // "ID3"
  let off = 10;
  for (const f of frames) {
    out.set(f, off);
    off += f.length;
  }
  if (footer) out.set([0x33, 0x44, 0x49, ...header], 10 + size); // "3DI"
  out.set(audio, tagEnd);
  writeFileSync(path, out);
  return { written: true, issue: null };
}

/**
 * Write provenance tags to one copied file; `key` is its sidecar audio_hash.
 * Never throws.
 */
export async function writeProvenance(path: string, tags: ProvenanceTags, key: string): Promise<TagWriteResult> {
  try {
    switch (ext(path)) {
      case "flac":
        // doc 03 execute step 2: none to a FLAC keyed by the fsha1: fallback.
        if (key.startsWith("fsha1:")) return { written: false, issue: "provenance_tags_skipped:flac_fsha1" };
        return await metaflacSetTags(path, tags);
      case "mp3":
        return mp3MergeTags(path, tags);
      default:
        return { written: false, issue: `provenance_tags_skipped:${ext(path)}` };
    }
  } catch (e) {
    return { written: false, issue: `provenance_write_failed: ${String(e).slice(0, 120)}` };
  }
}
