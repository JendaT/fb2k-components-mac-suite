// RAR writers for archive tests, built at test time so no `rar` binary is
// needed.
//
// RAR5, per the RAR 5.0 archive format technote (rarlab.com/technote.htm):
// signature, main archive header, file headers + data, end of archive
// header; every header is CRC32 + vint size + fields. Compression
// information bits 0-5 hold the algorithm version: 0 is RAR 5.0's, 1 is RAR
// 7.0's. 7-Zip lists them as `v6` and `v7`. p7zip 17.05 rejects version 1
// with "Unsupported Method" even for a stored entry (p7zip 16.02 predates RAR
// 7); 7-Zip 26.03 (7zz) extracts it.
//
// RAR 4.x (archive format 2.9), per the RAR 2.9 technote and libarchive's
// archive_read_support_format_rar.c: marker block, main header, file headers
// + data, end of archive block; every block is CRC16 (low half of the CRC32
// of the header from HEAD_TYPE on), type, flags, size, fields.
//
// A compressed entry (RAR5 method 3, RAR4 method 0x33, as `rar -m3` writes)
// holds one LZ block that codes every byte as a literal: a Huffman table
// with the literals at 8 bits and no match codes. Valid compressed data, and
// enough to show that a tool really decompresses (Homebrew's 7-Zip builds
// lack the RAR codec and fail it with "Unsupported Method").

import { decodeCodePage, type CodePage } from "../src/zipnames.ts";

function vint(n: number): number[] {
  const out: number[] = [];
  do {
    let b = n % 128;
    n = Math.floor(n / 128);
    if (n > 0) b |= 0x80;
    out.push(b);
  } while (n > 0);
  return out;
}

const u16 = (n: number) => [n & 0xff, (n >>> 8) & 0xff];
const u32 = (n: number) => [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];
const crc32 = (b: Uint8Array) => Bun.hash.crc32(b) >>> 0;
const utf8 = (s: string) => [...new TextEncoder().encode(s)];
/** Deterministic filler for encrypted data and headers. */
const filler = (n: number, mul: number) => Array.from({ length: n }, (_, i) => (i * mul + 7) & 0xff);

/** MSB-first bit writer, the bit order of RAR compressed data (RAR5 and 2.9). */
class BitWriter {
  bytes: number[] = [];
  private cur = 0;
  private n = 0;
  put(value: number, count: number): void {
    for (let i = count - 1; i >= 0; i--) {
      this.cur = (this.cur << 1) | ((value >>> i) & 1);
      if (++this.n === 8) {
        this.bytes.push(this.cur);
        this.cur = 0;
        this.n = 0;
      }
    }
  }
  /** Pad the last byte with zeros; returns the number of bits used in it (1-8). */
  finish(): number {
    if (this.n === 0) return 8;
    const used = this.n;
    this.bytes.push(this.cur << (8 - this.n));
    this.cur = 0;
    this.n = 0;
    return used;
  }
}

// ---------------------------------------------------------------- RAR5 ----

/** A header block: CRC32 of (size vint + body), size vint, body. */
function block(body: number[]): number[] {
  const sized = [...vint(body.length), ...body];
  return [...u32(crc32(new Uint8Array(sized))), ...sized];
}

/** An extra area record: size vint (of type + data), type vint, data. */
function extraRecord(type: number, data: number[]): number[] {
  const body = [...vint(type), ...data];
  return [...vint(body.length), ...body];
}

// Main table sizes for algorithm version 0: literals/lengths, distances,
// low distances, repeat lengths.
const NC = 306;
const DC = 64;
const LDC = 16;
const RC = 44;

/** One last, table-carrying RAR5 compressed block coding `data` as literals only. */
function literalBlock(data: Uint8Array): number[] {
  const w = new BitWriter();
  // Bit-length code (20 symbols, 4 bits each): symbols 0 and 8 at length 1,
  // so "0" means length 0 and "1" means length 8.
  for (let i = 0; i < 20; i++) w.put(i === 0 || i === 8 ? 1 : 0, 4);
  // Main tables: literals 0-255 at 8 bits, every other code unused.
  for (let i = 0; i < NC + DC + LDC + RC; i++) w.put(i < 256 ? 1 : 0, 1);
  for (const b of data) w.put(b, 8);
  const lastBits = w.finish();
  const size = w.bytes.length;
  const byteCount = size < 0x100 ? 1 : size < 0x10000 ? 2 : 3;
  const flags = 0x80 | 0x40 | ((byteCount - 1) << 3) | (lastBits - 1); // table present, last block
  const sizeBytes = [size & 0xff, (size >>> 8) & 0xff, (size >>> 16) & 0xff].slice(0, byteCount);
  const check = (0x5a ^ flags ^ size ^ (size >>> 8) ^ (size >>> 16)) & 0xff;
  return [flags, check, ...sizeBytes, ...w.bytes];
}

/** RAR5 redirection types: 1 Unix symlink, 2 Windows symlink, 3 junction, 4 hard link, 5 file copy. */
export type Rar5RedirType = 1 | 2 | 3 | 4 | 5;

export interface Rar5Entry {
  name: string;
  data?: Uint8Array; // unpacked content (default empty)
  algoVersion?: 0 | 1; // compression algorithm version (default 0)
  compressed?: boolean; // method 3 literal-only stream instead of stored (method 0)
  badCrc?: boolean; // store a wrong data CRC32
  blake2?: Uint8Array; // a 32-byte BLAKE2sp file hash record, instead of the CRC32
  encrypted?: boolean; // AES-256 file encryption record; the data area is filler bytes
  dir?: boolean; // a directory entry
  redirect?: { type: Rar5RedirType; target: string }; // redirection record, no data
  splitAfter?: boolean; // data area continues in the next volume
  mode?: number; // Unix mode attribute (default 0o40755 dir, 0o120777 symlink, 0o100644 file)
}

function fileHeader(e: Rar5Entry): number[] {
  const data = e.data ?? new Uint8Array();
  const nameBytes = utf8(e.name);
  let packed: number[] = e.compressed ? literalBlock(data) : [...data];
  const extra: number[] = [];
  if (e.encrypted) {
    const pad = (16 - (packed.length % 16)) % 16;
    packed = filler(packed.length + pad, 131);
    const salt = Array.from({ length: 16 }, (_, i) => i + 1);
    const iv = Array.from({ length: 16 }, (_, i) => 0xa0 + i);
    const check = Array.from({ length: 12 }, (_, i) => 0x50 + i);
    extra.push(...extraRecord(0x01, [...vint(0), ...vint(0x0001), 15, ...salt, ...iv, ...check]));
  }
  if (e.blake2) extra.push(...extraRecord(0x02, [...vint(0), ...e.blake2]));
  if (e.redirect !== undefined) {
    const target = utf8(e.redirect.target);
    extra.push(...extraRecord(0x05, [...vint(e.redirect.type), ...vint(0), ...vint(target.length), ...target]));
  }
  const method = e.compressed ? 3 : 0;
  const dictBits = e.compressed ? 0 : 8; // 128 KiB << n
  const compression = (e.algoVersion ?? 0) | (method << 7) | (dictBits << 10);
  const withCrc = e.blake2 === undefined && !e.dir;
  const crc = (crc32(data) ^ (e.badCrc ? 0xffffffff : 0)) >>> 0;
  const mode = e.mode ?? (e.dir ? 0o40755 : e.redirect?.type === 1 ? 0o120777 : 0o100644);
  const body = [
    ...vint(2), // type: file header
    ...vint((extra.length > 0 ? 0x0001 : 0) | 0x0002 | (e.splitAfter ? 0x0010 : 0)), // extra area, data area, split after
    ...(extra.length > 0 ? vint(extra.length) : []),
    ...vint(packed.length), // data size
    ...vint((e.dir ? 0x0001 : 0) | (withCrc ? 0x0004 : 0)), // file flags: directory, data CRC32 present
    ...vint(data.length), // unpacked size
    ...vint(mode), // attributes (Unix mode)
    ...(withCrc ? u32(crc) : []),
    ...vint(compression),
    ...vint(1), // host OS: Unix
    ...vint(nameBytes.length),
    ...nameBytes,
    ...extra,
  ];
  return [...block(body), ...packed];
}

const SIGNATURE = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00];

export interface Rar5Options {
  encryptedHeaders?: boolean; // archive encryption header; filler bytes stand in for the rest
  volume?: boolean; // main header volume flag, end header "not last volume"
}

export function buildRar5(entries: Rar5Entry[], opts: Rar5Options = {}): Uint8Array {
  const out: number[] = [...SIGNATURE];
  if (opts.encryptedHeaders) {
    // Archive encryption header (type 4): AES-256, password check present.
    // Every header after it is encrypted; filler bytes stand in for them.
    const salt = Array.from({ length: 16 }, (_, i) => i + 1);
    const check = Array.from({ length: 12 }, (_, i) => 0x50 + i);
    out.push(...block([...vint(4), ...vint(0), ...vint(0), ...vint(0x0001), 15, ...salt, ...check]));
    out.push(...filler(256, 167));
    return new Uint8Array(out);
  }
  out.push(...block([...vint(1), ...vint(0), ...vint(opts.volume ? 0x0001 : 0)])); // main header
  for (const e of entries) out.push(...fileHeader(e));
  out.push(...block([...vint(5), ...vint(0), ...vint(opts.volume ? 0x0001 : 0)])); // end of archive
  return new Uint8Array(out);
}

/** One stored (method 0) file entry. */
export function buildRar5Stored(name: string, data: Uint8Array, algoVersion: 0 | 1): Uint8Array {
  return buildRar5([{ name, data, algoVersion }]);
}

// ---------------------------------------------------------------- RAR4 ----

/** A RAR4 block: CRC16, type, flags, size (of the header, data excluded), fields, then data. */
function block4(type: number, flags: number, fields: number[], data: number[] = []): number[] {
  const body = [type, ...u16(flags), ...u16(7 + fields.length), ...fields];
  return [...u16(crc32(new Uint8Array(body)) & 0xffff), ...body, ...data];
}

/** RAR 2.9 LZ block coding `data` as literals only, ended by an end-of-block code. */
function literalBlock29(data: Uint8Array): number[] {
  const w = new BitWriter();
  w.put(0, 1); // LZ block, not PPMd
  w.put(0, 1); // fresh tables, not added to the previous ones
  // Bit-length code (20 symbols, 4 bits each): 8 at length 1 ("0"), 0 and 9
  // at length 2 ("10", "11").
  for (let i = 0; i < 20; i++) w.put(i === 8 ? 1 : i === 0 || i === 9 ? 2 : 0, 4);
  // Main tables (299 + 60 + 17 + 28): literals 0-254 at 8 bits, literal 255
  // and 256 (end of block) at 9 bits, every other code unused. Canonical
  // codes: a literal b < 255 is b itself, 255 is 111111110, 256 is 111111111.
  for (let i = 0; i < 404; i++) {
    if (i < 255) w.put(0b0, 1);
    else if (i < 257) w.put(0b11, 2);
    else w.put(0b10, 2);
  }
  for (const b of data) {
    if (b < 255) w.put(b, 8);
    else w.put(0b111111110, 9);
  }
  w.put(0b111111111, 9); // end of block
  w.put(0b01, 2); // new file, new table at its start
  w.finish();
  return w.bytes;
}

/** OEM bytes of a name, one per UTF-16 unit; `?` for a char the code page lacks (as WinRAR writes). */
function oemBytes(name: string, cp: CodePage, strict: boolean): number[] {
  const high = decodeCodePage(Uint8Array.from({ length: 128 }, (_, i) => 0x80 + i), cp);
  return [...name].flatMap((ch) => {
    const c = ch.charCodeAt(0);
    if (ch.length === 1 && c < 0x80) return [c];
    const at = high.indexOf(ch);
    if (at >= 0) return [0x80 + at];
    if (strict) throw new Error(`"${ch}" is not in cp${cp}`);
    return Array.from({ length: ch.length }, () => 0x3f);
  });
}

/**
 * RAR's compressed Unicode name (the part after the OEM name and a zero
 * byte): a high byte, then groups of four 2-bit ops, each group led by its
 * flag byte. Op 0: one byte, high byte 0. Op 1: one byte, high byte = the
 * shared high byte. Op 2: two bytes, low then high. Op 3: a run copied from
 * the OEM name (length - 2 in the low 7 bits), or with the top bit set and a
 * correction byte, chars with the shared high byte whose low byte is the OEM
 * byte plus the correction. Every op is used where the name allows, so a
 * test name covers every branch of a decoder.
 */
function encodeUnicodeName(name: string, oem: number[]): number[] {
  const units = Array.from({ length: name.length }, (_, i) => name.charCodeAt(i));
  const highs = units.map((u) => u >> 8).filter((h) => h !== 0);
  const highByte = highs.length > 0 ? highs[0]! : 0;
  const ops: { op: number; bytes: number[] }[] = [];
  const runOf = (from: number, same: (k: number) => boolean) => {
    let n = 0;
    while (from + n < units.length && n < 0x7f + 2 && same(from + n)) n++;
    return n;
  };
  let i = 0;
  while (i < units.length) {
    const u = units[i]!;
    const run = runOf(i, (k) => units[k]! < 0x80 && oem[k] === units[k]);
    if (run >= 2) {
      ops.push({ op: 3, bytes: [run - 2] });
      i += run;
      continue;
    }
    const corr = ((u & 0xff) - oem[i]!) & 0xff;
    const crun = highByte === 0 ? 0 : runOf(i, (k) => units[k]! >> 8 === highByte && (((units[k]! & 0xff) - oem[k]!) & 0xff) === corr);
    if (crun >= 2) {
      ops.push({ op: 3, bytes: [0x80 | (crun - 2), corr] });
      i += crun;
      continue;
    }
    if (u >> 8 === 0) ops.push({ op: 0, bytes: [u] });
    else if (u >> 8 === highByte) ops.push({ op: 1, bytes: [u & 0xff] });
    else ops.push({ op: 2, bytes: [u & 0xff, u >> 8] });
    i++;
  }
  const out = [highByte];
  for (let g = 0; g < ops.length; g += 4) {
    const group = ops.slice(g, g + 4);
    out.push(group.reduce((f, o, k) => f | (o.op << (6 - 2 * k)), 0));
    for (const o of group) out.push(...o.bytes);
  }
  return out;
}

export interface Rar4Entry {
  name: string; // "/"-separated; a Windows-host entry stores it with backslashes, as WinRAR does
  data?: Uint8Array; // unpacked content (default empty)
  /**
   * Name field form: "oem" (default; bytes in `codePage`, no Unicode flag),
   * "unicode" (Unicode flag, OEM name + zero + compressed Unicode name),
   * "utf8" (Unicode flag, UTF-8 bytes, no zero).
   */
  names?: "oem" | "unicode" | "utf8";
  codePage?: CodePage; // OEM code page of the name bytes (default 437)
  compressed?: boolean; // method 0x33 literal-only stream instead of stored (0x30)
  badCrc?: boolean; // store a wrong file CRC32
  encrypted?: boolean; // password flag + salt; the data area is filler bytes
  dir?: boolean; // a directory entry
  solid?: boolean; // solid flag: the entry continues the previous entry's stream
  splitAfter?: boolean; // data continues in the next volume
  unixSymlink?: string; // Unix-host symlink to this target (stored as the data)
}

export interface Rar4Options {
  encryptedHeaders?: boolean; // main header password flag; filler bytes stand in for the rest
  volume?: boolean; // first volume of a set: volume flags, end block "next volume"
  solid?: boolean; // main header solid flag
}

const RAR4_SIGNATURE = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00];
const DOS_TIME = (30 << 25) | (6 << 21) | (15 << 16) | (12 << 11); // 2010-06-15 12:00

function fileBlock4(e: Rar4Entry): number[] {
  const unix = e.unixSymlink !== undefined;
  const data = unix ? new TextEncoder().encode(e.unixSymlink) : (e.data ?? new Uint8Array());
  const stored = unix ? e.name : e.name.replaceAll("/", "\\");
  const cp = e.codePage ?? 437;
  const form = e.names ?? "oem";
  let name: number[];
  if (form === "oem") name = oemBytes(stored, cp, true);
  else if (form === "utf8") name = utf8(stored);
  else {
    const oem = oemBytes(stored, cp, false);
    name = [...oem, 0, ...encodeUnicodeName(stored, oem)];
  }
  let packed: number[] = e.compressed ? literalBlock29(data) : [...data];
  if (e.encrypted) packed = filler(packed.length + ((16 - (packed.length % 16)) % 16), 131);
  const flags =
    0x8000 | // data follows the header
    (e.splitAfter ? 0x0002 : 0) |
    (e.encrypted ? 0x0004 | 0x0400 : 0) | // password, salt
    (e.solid ? 0x0010 : 0) |
    (e.dir ? 0x00e0 : 0) | // dictionary bits all set: directory
    (form !== "oem" ? 0x0200 : 0);
  const crc = e.dir ? 0 : (crc32(data) ^ (e.badCrc ? 0xffffffff : 0)) >>> 0;
  const attr = unix ? 0o120777 : e.dir ? 0x10 : 0x20; // Unix mode, or Windows directory / archive attribute
  const fields = [
    ...u32(packed.length),
    ...u32(data.length),
    unix ? 3 : 2, // host OS: Unix, Win32
    ...u32(crc),
    ...u32(DOS_TIME),
    29, // version needed: 2.9
    e.compressed ? 0x33 : 0x30, // method: normal, store
    ...u16(name.length),
    ...u32(attr),
    ...name,
    ...(e.encrypted ? [1, 2, 3, 4, 5, 6, 7, 8] : []), // salt
  ];
  return block4(0x74, flags, fields, packed);
}

export function buildRar4(entries: Rar4Entry[], opts: Rar4Options = {}): Uint8Array {
  const out: number[] = [...RAR4_SIGNATURE];
  const mainFlags =
    (opts.volume ? 0x0001 | 0x0010 | 0x0100 : 0) | // volume, new numbering, first volume
    (opts.solid ? 0x0008 : 0) |
    (opts.encryptedHeaders ? 0x0080 : 0);
  out.push(...block4(0x73, mainFlags, [0, 0, 0, 0, 0, 0])); // reserved fields
  if (opts.encryptedHeaders) {
    out.push(...filler(256, 167));
    return new Uint8Array(out);
  }
  for (const e of entries) out.push(...fileBlock4(e));
  out.push(...block4(0x7b, opts.volume ? 0x0001 : 0, [])); // end of archive (next volume follows)
  return new Uint8Array(out);
}
