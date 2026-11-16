// RAR headers, read before extraction and used to verify it (src/archive.ts).
// bsdtar's exit code cannot be trusted for rar: libarchive 3.7.4 exits 0
// after writing a stored member whose CRC32 does not match (RAR4 and RAR5),
// the ciphertext of an encrypted stored member, the first part of a
// multi-volume set, and a 0-byte file for a RAR5 file-copy entry. So:
// 1. readRarHeaders reads every header of a RAR4 (format 2.9) or RAR5
//    archive and refuses, before anything is written: multi-volume (volume
//    flag, split entry, `.partN.rar` name), header encryption, an encrypted
//    entry, a data entry without a CRC32 (RAR5 BLAKE2-only), RAR5 hard
//    link, file copy and junction entries, Unix special files, unsafe paths
//    (absolute or `..`), duplicate paths, and unreadable or damaged headers.
//    Solid RAR4 (main header solid flag or an entry's LHD_SOLID) is refused
//    too unless the caller allows it (`solidRar4`): libarchive 3.7.4 writes
//    the first member and then fails with "RAR solid archive support
//    unavailable", so archive.ts allows it only when unar is on PATH and
//    sends it there (RarHeaders.solidRar4). Every other refusal applies to
//    it as to any rar. libarchive's RAR5 reader handles solid archives, so
//    RAR5 solid is allowed and stays with bsdtar.
// 2. verifyRarExtraction checks the extracted tree against the headers:
//    each data entry present, with its size and CRC32 (streamed), and no
//    file that the headers do not list.
//
// Formats: RAR 5.0 technote (rarlab.com/technote.htm); RAR 2.9 header layout
// as libarchive's archive_read_support_format_rar.c reads it. Entry names
// are the paths libarchive writes: RAR5 names are UTF-8; RAR4 names are
// UTF-8 (Unicode flag, no zero byte), RAR's compressed Unicode encoding
// (Unicode flag, OEM name + zero + encoding; decoded as libarchive does), or
// plain OEM bytes. Plain non-ASCII OEM names are decoded with the code page
// zipnames.ts chooses by scoring cp437, cp852, cp1252 and cp1250 (RAR4 does
// not record which), and bsdtar gets the same one
// (`rar:hdrcharset`): on its own it writes the raw bytes, which APFS refuses
// ("Illegal byte sequence"). bsdtar decodes through iconv, whose tables the
// TS ones match byte for byte; libarchive 3.7.4 on macOS takes all four
// (checked with every defined byte of each). unar (solid RAR4) gets it as
// `-e` and matches the TS tables the same way (unar 1.10.7, every defined
// byte of each page; see archive.ts). Names that are not text in any of the
// four (a control char) are refused. libarchive turns `\` into `/` in every
// RAR4 name; unar splits on `\` only and writes a `/` inside a name as `:`,
// so such a name fails the check after unar. On macOS libarchive writes
// names as UTF-8 NFD whatever the locale (checked with C, UTF-8 and
// ISO8859-2 locales), so names are matched NFC-normalized; SMB shares also
// hand back NFD.

import { closeSync, fstatSync, lstatSync, openSync, readdirSync, readSync } from "node:fs";
import { basename, join } from "node:path";
import { crc32 } from "node:zlib";
import { chooseCodePage, decodeCodePage, isValidUtf8, undecodableNames, type CodePage, type CodePageChoice } from "./zipnames.ts";

export interface RarEntry {
  /** "/"-separated relative path as extracted, NFC: the match key. */
  path: string;
  /** dir and link entries carry no data to verify. */
  kind: "file" | "dir" | "link";
  crc32: number;
  /** Unpacked size; null when the header leaves it unknown. */
  size: number | null;
}

export interface RarHeaders {
  format: 4 | 5;
  entries: RarEntry[];
  /** Code page of plain non-ASCII RAR4 names (for bsdtar's `rar:hdrcharset`, unar's `-e`) and how it was chosen; null when there are none. */
  codePage: CodePageChoice | null;
  /** A solid RAR4 (main header solid flag or an entry's LHD_SOLID), read with `solidRar4` allowed; false for RAR5. */
  solidRar4: boolean;
}

export interface RarHeaderOptions {
  /** Accept a solid RAR4 instead of refusing it (archive.ts: unar is on PATH). */
  solidRar4?: boolean;
}

/** A refusal: the archive is not extracted. */
class Refusal extends Error {}

const damaged = (detail: string) => new Refusal(`damaged rar headers: ${detail}`);
const entryRefusal = (name: string, reason: string) => new Refusal(`rar entry "${name}": ${reason}`);
const MULTI_VOLUME = "multi-volume rar is not supported";
const SOLID_RAR4 = "solid RAR4 is not supported without unar on PATH";

const RAR5_SIG = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00];
const RAR4_SIG = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00];

/** Bounded reads from the archive file. */
class Source {
  constructor(
    private fd: number,
    readonly size: number,
  ) {}
  read(pos: number, len: number): Uint8Array {
    if (pos < 0 || len < 0 || pos + len > this.size) throw damaged(`truncated at offset ${pos}`);
    const buf = new Uint8Array(len);
    let got = 0;
    while (got < len) {
      const n = readSync(this.fd, buf, got, len - got, pos + got);
      if (n === 0) throw damaged(`truncated at offset ${pos}`);
      got += n;
    }
    return buf;
  }
}

/** Cursor over one header's bytes; reading past the end means a damaged header. */
class Cursor {
  constructor(
    private b: Uint8Array,
    public at = 0,
    private end = b.length,
  ) {}
  get left(): number {
    return this.end - this.at;
  }
  private need(n: number): void {
    if (this.at + n > this.end) throw damaged("header field runs past its header");
  }
  u8(): number {
    this.need(1);
    return this.b[this.at++]!;
  }
  u16(): number {
    this.need(2);
    const v = this.b[this.at]! | (this.b[this.at + 1]! << 8);
    this.at += 2;
    return v;
  }
  u32(): number {
    this.need(4);
    const v = (this.b[this.at]! | (this.b[this.at + 1]! << 8) | (this.b[this.at + 2]! << 16) | (this.b[this.at + 3]! << 24)) >>> 0;
    this.at += 4;
    return v;
  }
  bytes(n: number): Uint8Array {
    this.need(n);
    const v = this.b.subarray(this.at, this.at + n);
    this.at += n;
    return v;
  }
  /** RAR5 variable-length integer: 7 bits per byte, low first, high bit = more. */
  vint(): number {
    let v = 0;
    let mul = 1;
    for (let i = 0; i < 10; i++) {
      const b = this.u8();
      v += (b & 0x7f) * mul;
      if ((b & 0x80) === 0) {
        if (!Number.isSafeInteger(v)) throw damaged("number too large");
        return v;
      }
      mul *= 128;
    }
    throw damaged("variable-length number too long");
  }
}

const crc32Of = (b: Uint8Array): number => crc32(b) >>> 0;

/** A header entry before path checks: the decoded name, or raw OEM bytes still to decode. */
interface RawEntry {
  name: string | Uint8Array;
  kind: RarEntry["kind"];
  crc32: number;
  size: number | null;
}

/**
 * Read and check the headers of a rar archive. Returns the entries, or an
 * error (the reason the archive is refused). Reads only headers: data areas
 * are skipped by their size. `prefer` orders code page ties (income.yaml
 * `archive_code_pages`). A solid RAR4 is refused unless `opts.solidRar4`.
 */
export function readRarHeaders(
  path: string, prefer: readonly CodePage[] = [], opts: RarHeaderOptions = {},
): RarHeaders | { error: string } {
  if (/\.part\d+\.rar$/i.test(basename(path))) return { error: MULTI_VOLUME };
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch (e) {
    return { error: `cannot read rar: ${e instanceof Error ? e.message : String(e)}` };
  }
  try {
    const src = new Source(fd, fstatSync(fd).size);
    const sig = src.read(0, Math.min(8, src.size));
    const starts = (s: number[]) => sig.length >= s.length && s.every((b, i) => sig[i] === b);
    let raw: RawEntry[];
    let format: 4 | 5;
    let solidRar4 = false;
    if (starts(RAR5_SIG)) {
      format = 5;
      raw = readRar5(src);
    } else if (starts(RAR4_SIG)) {
      format = 4;
      ({ entries: raw, solid: solidRar4 } = readRar4(src, opts.solidRar4 ?? false));
    } else {
      return { error: "not a rar archive: no RAR signature at the start" };
    }
    const plain = raw.filter((e): e is RawEntry & { name: Uint8Array } => e.name instanceof Uint8Array);
    let codePage: CodePageChoice | null = null;
    if (plain.some((e) => e.name.some((b) => b >= 0x80))) {
      codePage = chooseCodePage({ entries: plain.map((e) => ({ flags: 0, name: e.name })) }, path, prefer);
      if (codePage === null) throw new Refusal(undecodableNames(path));
    }
    const entries: RarEntry[] = [];
    const seen = new Set<string>();
    for (const e of raw) {
      const name = typeof e.name === "string" ? e.name : decodeCodePage(e.name, codePage?.cp ?? 437);
      const p = checkedPath(name);
      if (e.kind === "file") {
        if (seen.has(p)) throw entryRefusal(p, "duplicate path");
        seen.add(p);
      }
      entries.push({ path: p, kind: e.kind, crc32: e.crc32, size: e.size });
    }
    return { format, entries, codePage, solidRar4 };
  } catch (e) {
    if (e instanceof Refusal) return { error: e.message };
    return { error: `cannot read rar: ${e instanceof Error ? e.message : String(e)}` };
  } finally {
    closeSync(fd);
  }
}

/** The match key of an entry name ("/"-separated); refuses absolute and `..` paths. */
function checkedPath(name: string): string {
  const display = name.normalize("NFC");
  if (name.startsWith("/") || /^[A-Za-z]:/.test(name)) throw entryRefusal(display, "unsafe path (absolute)");
  const segs = name.split("/").filter((s) => s !== "" && s !== ".");
  if (segs.includes("..")) throw entryRefusal(display, "unsafe path (..)");
  if (segs.length === 0) throw entryRefusal(display, "empty path");
  return segs.join("/").normalize("NFC");
}

function utf8Name(bytes: Uint8Array): string {
  if (!isValidUtf8(bytes)) throw entryRefusal(decodeCodePage(bytes, 1252), "name is not valid UTF-8");
  return new TextDecoder().decode(bytes);
}

// ---------------------------------------------------------------- RAR5 ----

const R5_HEAD_MAIN = 1;
const R5_HEAD_FILE = 2;
const R5_HEAD_SERVICE = 3;
const R5_HEAD_CRYPT = 4;
const R5_HEAD_END = 5;
const R5_HFL_EXTRA = 0x0001;
const R5_HFL_DATA = 0x0002;
const R5_HFL_SKIP_UNKNOWN = 0x0004;
const R5_HFL_SPLIT = 0x0008 | 0x0010; // continues from previous / in next volume
const R5_FILE_DIR = 0x0001;
const R5_FILE_MTIME = 0x0002;
const R5_FILE_CRC = 0x0004;
const R5_FILE_UNKNOWN_SIZE = 0x0008;
const R5_REDIR_NAMES: Record<number, string> = { 3: "junction", 4: "hard link", 5: "file copy" };

function readRar5(src: Source): RawEntry[] {
  const entries: RawEntry[] = [];
  let pos = RAR5_SIG.length;
  for (;;) {
    if (pos >= src.size) throw damaged("no end of archive header");
    // CRC32, then the header size vint (at most 3 bytes in RAR 5.0).
    const head = src.read(pos, Math.min(7, src.size - pos));
    const c = new Cursor(head, 4);
    const size = c.vint();
    const sizeLen = c.at - 4;
    if (size === 0 || size > 2 * 1024 * 1024) throw damaged(`bad header size at offset ${pos}`);
    const block = src.read(pos + 4, sizeLen + size);
    const stored = (head[0]! | (head[1]! << 8) | (head[2]! << 16) | (head[3]! << 24)) >>> 0;
    if (crc32Of(block) !== stored) throw damaged(`header CRC mismatch at offset ${pos}`);
    const h = new Cursor(block, sizeLen);
    const type = h.vint();
    const flags = h.vint();
    const extraSize = flags & R5_HFL_EXTRA ? h.vint() : 0;
    const dataSize = flags & R5_HFL_DATA ? h.vint() : 0;
    const extraStart = block.length - extraSize;
    if (extraStart < h.at) throw damaged(`extra area larger than its header at offset ${pos}`);
    const next = pos + 4 + block.length + dataSize;
    if (next > src.size) throw damaged(`data area runs past the end of the file at offset ${pos}`);

    if (type === R5_HEAD_CRYPT) throw new Refusal("header-encrypted rar is not supported");
    if (type === R5_HEAD_MAIN) {
      const archiveFlags = h.vint();
      if (archiveFlags & 0x0001) throw new Refusal(MULTI_VOLUME);
    } else if (type === R5_HEAD_END) {
      const endFlags = h.vint();
      if (endFlags & 0x0001) throw new Refusal(MULTI_VOLUME); // not the last volume
      return entries;
    } else if (type === R5_HEAD_SERVICE) {
      if (flags & R5_HFL_SPLIT) throw new Refusal(MULTI_VOLUME);
    } else if (type === R5_HEAD_FILE) {
      entries.push(rar5File(h, block, extraStart, flags));
    } else if (!(flags & R5_HFL_SKIP_UNKNOWN)) {
      throw damaged(`unknown header type ${type} at offset ${pos}`);
    }
    pos = next;
  }
}

function rar5File(h: Cursor, block: Uint8Array, extraStart: number, headerFlags: number): RawEntry {
  const fileFlags = h.vint();
  const unpacked = h.vint();
  const attributes = h.vint();
  if (fileFlags & R5_FILE_MTIME) h.u32();
  const crc = fileFlags & R5_FILE_CRC ? h.u32() : null;
  h.vint(); // compression information
  const hostOs = h.vint();
  const name = utf8Name(h.bytes(h.vint()));
  if (h.at > extraStart) throw damaged(`file header fields overlap its extra area ("${name}")`);
  const display = name.normalize("NFC");

  let encrypted = false;
  let blake2 = false;
  let redir: number | null = null;
  const x = new Cursor(block, extraStart);
  while (x.left > 0) {
    const recSize = x.vint();
    const recEnd = x.at + recSize;
    if (recSize === 0 || recEnd > block.length) throw damaged(`bad extra record in "${display}"`);
    const r = new Cursor(block, x.at, recEnd);
    const type = r.vint();
    if (type === 0x01) encrypted = true;
    else if (type === 0x02) blake2 = r.vint() === 0; // hash type 0: BLAKE2sp
    else if (type === 0x05) redir = r.vint();
    x.at = recEnd;
  }

  if (headerFlags & R5_HFL_SPLIT) throw new Refusal(MULTI_VOLUME);
  const dir = (fileFlags & R5_FILE_DIR) !== 0;
  if (encrypted && !dir) throw entryRefusal(display, "encrypted");
  if (redir !== null) {
    // Unix or Windows symlink: bsdtar writes a link, stripSymlinks removes it.
    if (redir === 1 || redir === 2) return { name, kind: "link", crc32: 0, size: null };
    // libarchive 3.7.4 writes a hard link as a link to the target, and a file
    // copy or junction as a 0-byte file.
    throw entryRefusal(display, `${R5_REDIR_NAMES[redir] ?? `redirection type ${redir}`} entry, not supported`);
  }
  if (dir) return { name, kind: "dir", crc32: 0, size: null };
  if (hostOs === 1) checkUnixMode(display, attributes);
  if (crc === null) throw entryRefusal(display, blake2 ? "BLAKE2 hash only, cannot verify" : "no CRC32, cannot verify");
  return { name, kind: "file", crc32: crc, size: fileFlags & R5_FILE_UNKNOWN_SIZE ? null : unpacked };
}

/** A Unix-host entry that is neither a regular file nor a directory nor a symlink (a FIFO, a device). */
function checkUnixMode(display: string, mode: number): void {
  const type = mode & 0o170000;
  if (type !== 0 && type !== 0o100000 && type !== 0o040000 && type !== 0o120000)
    throw entryRefusal(display, `special file (mode ${mode.toString(8)}), not supported`);
}

// ---------------------------------------------------------------- RAR4 ----

const R4_MAIN = 0x73;
const R4_FILE = 0x74;
const R4_NEWSUB = 0x7a;
const R4_END = 0x7b;
const R4_OTHER = new Set([0x75, 0x76, 0x77, 0x78, 0x79]); // comment, AV, sub, recovery, sign
const R4_LONG_BLOCK = 0x8000; // ADD_SIZE (data size) follows the fixed fields
const MHD_VOLUME = 0x0001;
const MHD_SOLID = 0x0008;
const MHD_PASSWORD = 0x0080;
const LHD_SPLIT = 0x0001 | 0x0002; // continued from previous / in next volume
const LHD_PASSWORD = 0x0004;
const LHD_SOLID = 0x0010; // continues the previous entry's solid stream
const LHD_DIRECTORY = 0x00e0; // all dictionary bits set
const LHD_LARGE = 0x0100;
const LHD_UNICODE = 0x0200;
const EARC_NEXT_VOLUME = 0x0001;

/** The entries of a RAR4, and whether it is solid; a solid one is refused unless `allowSolid`. */
function readRar4(src: Source, allowSolid: boolean): { entries: RawEntry[]; solid: boolean } {
  const entries: RawEntry[] = [];
  let solid = false;
  let pos = RAR4_SIG.length;
  for (;;) {
    if (pos >= src.size) throw damaged("no end of archive block");
    const fixed = new Cursor(src.read(pos, 7));
    const crc = fixed.u16();
    const type = fixed.u8();
    const flags = fixed.u16();
    const size = fixed.u16();
    if (size < 7) throw damaged(`bad header size at offset ${pos}`);
    const header = src.read(pos, size);
    const h = new Cursor(header, 7);
    const checked = type === R4_MAIN || type === R4_FILE || type === R4_NEWSUB;
    if (checked && (crc32Of(header.subarray(2)) & 0xffff) !== crc) throw damaged(`header CRC mismatch at offset ${pos}`);

    let dataSize = 0;
    if (type === R4_MAIN) {
      if (flags & MHD_PASSWORD) throw new Refusal("header-encrypted rar is not supported");
      if (flags & MHD_VOLUME) throw new Refusal(MULTI_VOLUME);
      if (flags & MHD_SOLID) {
        if (!allowSolid) throw new Refusal(SOLID_RAR4);
        solid = true;
      }
    } else if (type === R4_NEWSUB) {
      // A service block (comment, recovery record, NTFS stream...) has the
      // file header layout; only its data size and volume flags matter.
      dataSize = h.u32();
      if (flags & LHD_LARGE) dataSize += new Cursor(header, 32).u32() * 2 ** 32;
      if (flags & LHD_SPLIT) throw new Refusal(MULTI_VOLUME);
    } else if (type === R4_FILE) {
      const f = rar4File(h, flags);
      dataSize = f.packed;
      if (flags & LHD_SPLIT) throw new Refusal(MULTI_VOLUME);
      if (flags & LHD_SOLID) {
        if (!allowSolid) throw new Refusal(`${SOLID_RAR4} (entry "${f.display}" continues a solid stream)`);
        solid = true;
      }
      if (flags & LHD_PASSWORD && f.entry.kind !== "dir") throw entryRefusal(f.display, "encrypted");
      if (f.unixMode !== null && f.entry.kind === "file") checkUnixMode(f.display, f.unixMode);
      entries.push(f.entry);
    } else if (type === R4_END) {
      if (flags & EARC_NEXT_VOLUME) throw new Refusal(MULTI_VOLUME);
      return { entries, solid };
    } else if (R4_OTHER.has(type)) {
      if (flags & R4_LONG_BLOCK) dataSize = h.u32();
    } else {
      throw damaged(`unknown header type 0x${type.toString(16)} at offset ${pos}`);
    }
    const next = pos + size + dataSize;
    if (next > src.size) throw damaged(`data area runs past the end of the file at offset ${pos}`);
    pos = next;
  }
}

function rar4File(h: Cursor, flags: number): { entry: RawEntry; packed: number; display: string; unixMode: number | null } {
  let packed = h.u32();
  let unpacked = h.u32();
  const hostOs = h.u8();
  const crc = h.u32();
  h.u32(); // DOS time
  h.u8(); // version needed
  h.u8(); // method
  const nameSize = h.u16();
  const attr = h.u32();
  if (flags & LHD_LARGE) {
    packed += h.u32() * 2 ** 32;
    unpacked += h.u32() * 2 ** 32;
  }
  const field = h.bytes(nameSize);
  let name: string | Uint8Array;
  if (flags & LHD_UNICODE) {
    const zero = field.indexOf(0);
    name = zero < 0 ? utf8Name(field) : decodeRar4Unicode(field, zero);
    name = name.replaceAll("\\", "/");
  } else {
    name = field.map((b) => (b === 0x5c ? 0x2f : b)); // `\` -> `/`, as libarchive does
  }
  const display = (typeof name === "string" ? name : decodeCodePage(name, 437)).normalize("NFC");
  // libarchive takes the type from the attributes: DOS/OS2/Win32 hosts (0-2)
  // carry the directory attribute, Unix/Mac/BeOS hosts (3-5) a Unix mode.
  const unixHost = hostOs >= 3 && hostOs <= 5;
  const dir = (flags & LHD_DIRECTORY) === LHD_DIRECTORY || (unixHost ? (attr & 0o170000) === 0o040000 : (attr & 0x10) !== 0);
  const link = unixHost && (attr & 0o170000) === 0o120000;
  const kind: RarEntry["kind"] = dir ? "dir" : link ? "link" : "file";
  return {
    entry: { name, kind, crc32: crc, size: kind === "file" ? unpacked : null },
    packed,
    display,
    unixMode: unixHost ? attr : null,
  };
}

/**
 * RAR's compressed Unicode name, decoded as libarchive 3.7.4 does: after the
 * OEM name and its zero byte, a high byte, then groups of four 2-bit ops,
 * each group led by its flag byte. Op 0: one byte, high byte 0. Op 1: one
 * byte, high byte = the shared high byte. Op 2: two bytes, low then high.
 * Op 3: a length byte (low 7 bits + 2 chars); with its top bit set, a
 * correction byte follows and each char is (OEM byte + correction) with the
 * shared high byte, else each char is the OEM byte; the OEM byte is the one
 * at the char's own index in the name field. The result is UTF-16, cut at a
 * NUL, as libarchive passes it on.
 */
function decodeRar4Unicode(field: Uint8Array, zero: number): string {
  const max = field.length; // libarchive's buffer: one char per field byte
  const units: number[] = [];
  let at = zero + 1;
  const byte = (): number => {
    if (at >= field.length) throw damaged("Unicode name runs past its field");
    return field[at++]!;
  };
  const high = byte();
  let flagByte = 0;
  let flagBits = 0;
  while (at < field.length && units.length < max) {
    if (flagBits === 0) {
      flagByte = byte();
      flagBits = 8;
    }
    flagBits -= 2;
    switch ((flagByte >> flagBits) & 3) {
      case 0:
        units.push(byte());
        break;
      case 1:
        units.push((high << 8) | byte());
        break;
      case 2: {
        const lo = byte();
        units.push(lo | (byte() << 8));
        break;
      }
      default: {
        const len = byte();
        const [extra, hi] = len & 0x80 ? [byte(), high] : [0, 0];
        for (let n = (len & 0x7f) + 2; n > 0 && units.length < max; n--) {
          units.push((hi << 8) | ((field[units.length]! + extra) & 0xff));
        }
      }
    }
  }
  const nul = units.indexOf(0);
  return String.fromCharCode(...(nul < 0 ? units : units.slice(0, nul)));
}

// -------------------------------------------------------- verification ----

async function crc32File(path: string): Promise<number> {
  let crc = 0;
  for await (const chunk of Bun.file(path).stream()) crc = crc32(chunk, crc);
  return crc >>> 0;
}

/**
 * Check an extracted tree (`dir`, after stripSymlinks) against the headers:
 * every data entry is a regular file of the header's size and CRC32, and
 * every regular file is a data entry. Directories carry no data and are not
 * compared. Returns null when everything matches, else the first problem
 * (by path) and how many more there are.
 */
export async function verifyRarExtraction(dir: string, headers: RarHeaders): Promise<string | null> {
  const expected = new Map(headers.entries.filter((e) => e.kind === "file").map((e) => [e.path, e]));
  const problems: { path: string; msg: string }[] = [];
  const found = new Set<string>();
  const walk = async (d: string, rel: string): Promise<void> => {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      const key = (rel === "" ? n : `${rel}/${n}`).normalize("NFC");
      const st = lstatSync(p);
      if (st.isDirectory()) {
        await walk(p, key);
        continue;
      }
      const entry = expected.get(key);
      if (!st.isFile()) {
        problems.push({ path: key, msg: `rar extraction wrote "${key}", which is not a regular file` });
      } else if (entry === undefined) {
        problems.push({ path: key, msg: `rar extraction wrote "${key}", which is not in the archive headers` });
      } else {
        found.add(key);
        if (entry.size !== null && st.size !== entry.size) {
          problems.push({ path: key, msg: `rar entry "${key}": size mismatch (header ${entry.size}, extracted ${st.size})` });
        } else if ((await crc32File(p)) !== entry.crc32) {
          problems.push({ path: key, msg: `rar entry "${key}": CRC32 mismatch` });
        }
      }
    }
  };
  await walk(dir, "");
  for (const key of expected.keys()) {
    if (!found.has(key)) problems.push({ path: key, msg: `rar entry "${key}": missing after extraction` });
  }
  if (problems.length === 0) return null;
  problems.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return problems.length === 1 ? problems[0]!.msg : `${problems[0]!.msg} (+${problems.length - 1} more)`;
}
