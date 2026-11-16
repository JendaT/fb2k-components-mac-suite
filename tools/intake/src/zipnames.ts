// Zip entry names that are neither UTF-8-flagged nor valid UTF-8: raw
// Windows code-page bytes (general purpose bit 11 unset). unzip does not
// decode them (it writes the bytes raw or OEM-translated, which SMB and APFS
// refuse), and 7-Zip on macOS ignores `-mcp` (7zz 26.03 turns such bytes
// into private-use chars, p7zip 17.05 decodes Latin-1). So the code page is
// applied here: names are decoded with a TS table (cp1252 or cp437) and
// written into a copy of the zip as UTF-8 with bit 11 set, which 7-Zip
// extracts (src/archive.ts).

import { closeSync, fstatSync, openSync, readSync, writeSync } from "node:fs";
import { basename } from "node:path";

const UTF8_FLAG = 0x0800; // general purpose bit 11: name and comment are UTF-8
const CD_ENCRYPTED_FLAG = 0x2000; // general purpose bit 13: central directory is masked
const EOCD_SIG = 0x06054b50;
const ZIP64_LOCATOR_SIG = 0x07064b50;
const CD_SIG = 0x02014b50;
const LOCAL_SIG = 0x04034b50;

export interface CdEntry {
  flags: number; // general purpose bit flag
  name: Uint8Array; // raw name bytes
  localOffset: number; // offset of the entry's local file header
  record: Uint8Array; // the whole central directory record
}

/**
 * Entry names with their zip flags: a central directory, or any list of raw
 * names (src/rarheaders.ts passes plain RAR4 names with flags 0).
 */
export interface NameList {
  entries: readonly Pick<CdEntry, "flags" | "name">[];
}

export interface CentralDirectory {
  entries: CdEntry[];
  cdOffset: number;
  eocd: Uint8Array; // end of central directory record, comment included
}

const u16 = (b: Uint8Array, at: number) => b[at]! | (b[at + 1]! << 8);
const u32 = (b: Uint8Array, at: number) => (b[at]! | (b[at + 1]! << 8) | (b[at + 2]! << 16) | (b[at + 3]! << 24)) >>> 0;
const put16 = (b: Uint8Array, at: number, v: number) => {
  b[at] = v & 0xff;
  b[at + 1] = (v >>> 8) & 0xff;
};
const put32 = (b: Uint8Array, at: number, v: number) => {
  put16(b, at, v & 0xffff);
  put16(b, at + 2, (v >>> 16) & 0xffff);
};

function readAt(fd: number, pos: number, len: number): Uint8Array {
  const buf = new Uint8Array(len);
  let got = 0;
  while (got < len) {
    const n = readSync(fd, buf, got, len - got, pos + got);
    if (n === 0) throw new Error("unexpected end of zip");
    got += n;
  }
  return buf;
}

/**
 * Central directory of a zip: EOCD (found backwards past a comment of up to
 * 64 KiB), then each central directory header. Returns null for anything
 * this reader does not handle, and the caller then extracts as before with
 * unzip: ZIP64 (EOCD fields saturated or a ZIP64 locator present), split
 * archives, a masked central directory, or any inconsistency.
 */
export function readCentralDirectory(path: string): CentralDirectory | null {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return null;
  }
  try {
    const size = fstatSync(fd).size;
    if (size < 22) return null;
    const tailLen = Math.min(size, 22 + 0xffff);
    const tailPos = size - tailLen;
    const tail = readAt(fd, tailPos, tailLen);
    let at = -1;
    for (let i = tailLen - 22; i >= 0; i--) {
      if (u32(tail, i) === EOCD_SIG && i + 22 + u16(tail, i + 20) === tailLen) {
        at = i;
        break;
      }
    }
    if (at < 0) return null;
    const eocdPos = tailPos + at;
    const count = u16(tail, at + 10);
    const cdSize = u32(tail, at + 12);
    const cdOffset = u32(tail, at + 16);
    if (u16(tail, at + 4) !== 0 || u16(tail, at + 6) !== 0 || u16(tail, at + 8) !== count) return null; // split
    if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) return null; // ZIP64
    if (eocdPos >= 20 && u32(readAt(fd, eocdPos - 20, 4), 0) === ZIP64_LOCATOR_SIG) return null; // ZIP64
    if (cdOffset + cdSize > eocdPos) return null;

    const cd = readAt(fd, cdOffset, cdSize);
    const entries: CdEntry[] = [];
    let p = 0;
    for (let k = 0; k < count; k++) {
      if (p + 46 > cd.length || u32(cd, p) !== CD_SIG) return null;
      const flags = u16(cd, p + 8);
      const n = u16(cd, p + 28);
      const len = 46 + n + u16(cd, p + 30) + u16(cd, p + 32);
      if (p + len > cd.length) return null;
      if (flags & CD_ENCRYPTED_FLAG) return null;
      const localOffset = u32(cd, p + 42);
      if (u32(cd, p + 20) === 0xffffffff || u32(cd, p + 24) === 0xffffffff || localOffset === 0xffffffff) return null; // ZIP64
      entries.push({ flags, name: cd.slice(p + 46, p + 46 + n), localOffset, record: cd.slice(p, p + len) });
      p += len;
    }
    return { entries, cdOffset, eocd: tail.slice(at) };
  } catch {
    return null;
  } finally {
    closeSync(fd);
  }
}

export function isValidUtf8(bytes: Uint8Array): boolean {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

/** True when some name is neither UTF-8-flagged nor valid UTF-8 (pure ASCII is valid UTF-8). */
export function needsCodePage(cd: CentralDirectory): boolean {
  return cd.entries.some((e) => !(e.flags & UTF8_FLAG) && !isValidUtf8(e.name));
}

// Bytes 0x80-0xFF. cp1252 leaves 0x81, 0x8D, 0x8F, 0x90 and 0x9D undefined;
// they map to the C1 controls of the same value, as in the WHATWG
// windows-1252 decoder. 0xA0-0xFF of cp1252 equal Latin-1.
const CP1252_HIGH =
  "€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008dŽ\u008f" +
  "\u0090‘’“”•–—˜™š›œ\u009džŸ" +
  Array.from({ length: 0x60 }, (_, i) => String.fromCharCode(0xa0 + i)).join("");
const CP437_HIGH =
  "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»" +
  "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
  "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ";

export type CodePage = 1252 | 437;

/** Decode raw name bytes with a code page; ASCII bytes map to themselves. */
export function decodeCodePage(bytes: Uint8Array, cp: CodePage): string {
  const high = cp === 1252 ? CP1252_HIGH : CP437_HIGH;
  let s = "";
  for (const b of bytes) s += b < 0x80 ? String.fromCharCode(b) : high[b - 0x80]!;
  return s;
}

/**
 * The top-level dir of the archive: the first path segment, when every
 * entry name starts with that segment followed by "/". Null otherwise
 * (loose files, or several top-level dirs).
 */
function topLevelDir(cd: NameList): Uint8Array | null {
  const first = cd.entries[0]?.name;
  if (!first) return null;
  const slash = first.indexOf(0x2f);
  if (slash <= 0) return null;
  const seg = first.subarray(0, slash);
  const ok = cd.entries.every(
    (e) => e.name.length > slash && e.name[slash] === 0x2f && seg.every((b, i) => e.name[i] === b),
  );
  return ok ? seg : null;
}

/**
 * Code page for the non-UTF-8 names of a zip, by a fixed rule:
 * 1. If the top-level dir name has non-ASCII bytes and decodes, with cp1252
 *    or else cp437, to the archive's own file name without extension (both
 *    sides NFC-normalized), that code page. An ASCII top-level name decodes
 *    the same in both and says nothing, so this rule needs non-ASCII bytes.
 * 2. Else cp1252, if every non-ASCII byte of the unflagged names is in
 *    0xC0-0xFF (the Latin letters of cp1252).
 * 3. Else cp437, the zip specification's default.
 */
export function chooseCodePage(cd: NameList, archivePath: string): { cp: CodePage; rule: 1 | 2 | 3 } {
  const top = topLevelDir(cd);
  if (top && top.some((b) => b >= 0x80)) {
    const own = basename(archivePath).replace(/\.[^.]*$/, "").normalize("NFC");
    for (const cp of [1252, 437] as const) {
      if (decodeCodePage(top, cp).normalize("NFC") === own) return { cp, rule: 1 };
    }
  }
  const latin = cd.entries.every((e) => (e.flags & UTF8_FLAG) !== 0 || e.name.every((b) => b < 0x80 || b >= 0xc0));
  return latin ? { cp: 1252, rule: 2 } : { cp: 437, rule: 3 };
}

/** Copy [from, to) of fdIn to the current end of fdOut; returns the bytes written. */
function copyRange(fdIn: number, fdOut: number, from: number, to: number, outPos: number): number {
  const chunk = new Uint8Array(1 << 20);
  let pos = from;
  while (pos < to) {
    const n = readSync(fdIn, chunk, 0, Math.min(chunk.length, to - pos), pos);
    if (n === 0) throw new Error("unexpected end of zip");
    writeSync(fdOut, chunk, 0, n, outPos + (pos - from));
    pos += n;
  }
  return to - from;
}

/**
 * Write a copy of the zip at `src` to `dst` with every unflagged name decoded
 * with `cp` and stored as UTF-8 with bit 11 set, in both the local and the
 * central headers. Member data, extra fields, comments and anything between
 * members are copied byte for byte; offsets are shifted by the name length
 * changes. Throws when the local headers do not line up with the central
 * directory (members out of order, overlapping or missing).
 */
export function writeUtf8NamedCopy(src: string, dst: string, cd: CentralDirectory, cp: CodePage): void {
  const newName = cd.entries.map((e) =>
    e.flags & UTF8_FLAG ? e.name : new TextEncoder().encode(decodeCodePage(e.name, cp)),
  );
  const order = cd.entries.map((_, i) => i).sort((a, b) => cd.entries[a]!.localOffset - cd.entries[b]!.localOffset);
  const fdIn = openSync(src, "r");
  let fdOut: number | null = null;
  try {
    fdOut = openSync(dst, "w");
    const newOffset = new Array<number>(cd.entries.length);
    let out = 0;
    const write = (b: Uint8Array) => {
      writeSync(fdOut!, b, 0, b.length, out);
      out += b.length;
    };
    // Anything before the first member (e.g. a self-extractor stub) as is.
    const firstOffset = order.length > 0 ? cd.entries[order[0]!]!.localOffset : cd.cdOffset;
    out += copyRange(fdIn, fdOut, 0, firstOffset, out);
    for (let k = 0; k < order.length; k++) {
      const i = order[k]!;
      const e = cd.entries[i]!;
      const end = k + 1 < order.length ? cd.entries[order[k + 1]!]!.localOffset : cd.cdOffset;
      const head = readAt(fdIn, e.localOffset, 30);
      if (u32(head, 0) !== LOCAL_SIG) throw new Error(`no local header at ${e.localOffset}`);
      const oldNameLen = u16(head, 26);
      if (e.localOffset + 30 + oldNameLen > end) throw new Error(`member at ${e.localOffset} overlaps the next`);
      newOffset[i] = out;
      put16(head, 6, u16(head, 6) | UTF8_FLAG);
      put16(head, 26, newName[i]!.length);
      write(head);
      write(newName[i]!);
      out += copyRange(fdIn, fdOut, e.localOffset + 30 + oldNameLen, end, out); // extra, data, descriptor
    }
    const cdStart = out;
    for (let i = 0; i < cd.entries.length; i++) {
      const e = cd.entries[i]!;
      const fixed = e.record.slice(0, 46);
      put16(fixed, 8, e.flags | UTF8_FLAG);
      put16(fixed, 28, newName[i]!.length);
      put32(fixed, 42, newOffset[i]!);
      write(fixed);
      write(newName[i]!);
      write(e.record.subarray(46 + e.name.length)); // extra field and comment
    }
    const eocd = cd.eocd.slice();
    put32(eocd, 12, out - cdStart);
    put32(eocd, 16, cdStart);
    write(eocd);
  } finally {
    closeSync(fdIn);
    if (fdOut !== null) closeSync(fdOut);
  }
}
