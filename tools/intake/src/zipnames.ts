// Zip entry names that are neither UTF-8-flagged nor valid UTF-8: raw
// Windows code-page bytes (general purpose bit 11 unset). unzip does not
// decode them (it writes the bytes raw or OEM-translated, which SMB and APFS
// refuse), and 7-Zip on macOS ignores `-mcp` (7zz 26.03 turns such bytes
// into private-use chars, p7zip 17.05 decodes Latin-1). So the code page is
// applied here: names are decoded with a TS table and written into a copy of
// the zip as UTF-8 with bit 11 set, which 7-Zip extracts (src/archive.ts).
// Plain RAR4 names use the same choice (src/rarheaders.ts).
//
// Candidates: cp437 and cp852 (DOS/OEM: US and Central European), cp1252 and
// cp1250 (Windows/ANSI: Western and Central European). Neither zip nor RAR4
// says which family a name is in, so all four are scored for every archive
// (chooseCodePage): every name is decoded with each, a candidate that yields
// a control char (or an undefined byte) is out, the lowest penalty wins, and
// a real tie is broken by the archive's own name or else by a fixed order
// (DEFAULT_CODE_PAGE_ORDER, reordered by income.yaml `archive_code_pages`).
// The tables match macOS iconv (CP437, CP852, CP1252, CP1250) byte for byte,
// as bsdtar's `rar:hdrcharset` decodes through iconv.

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

// Bytes 0x80-0xFF. The bytes a Windows code page leaves undefined (cp1252:
// 0x81, 0x8D, 0x8F, 0x90, 0x9D; cp1250: 0x81, 0x83, 0x88, 0x90, 0x98) map to
// the C1 control of the same value, as in the WHATWG decoders, so a
// candidate that meets one is out like one that yields any other control.
// 0xA0-0xFF of cp1252 equal Latin-1.
const CP1252_HIGH =
  "€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008dŽ\u008f" +
  "\u0090‘’“”•–—˜™š›œ\u009džŸ" +
  Array.from({ length: 0x60 }, (_, i) => String.fromCharCode(0xa0 + i)).join("");
const CP1250_HIGH =
  "€\u0081‚\u0083„…†‡\u0088‰Š‹ŚŤŽŹ" +
  "\u0090‘’“”•–—\u0098™š›śťžź" +
  "\u00a0ˇ˘Ł¤Ą¦§¨©Ş«¬\u00ad®Ż°±˛ł´µ¶·¸ąş»Ľ˝ľż" +
  "ŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢßŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙";
const CP437_HIGH =
  "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»" +
  "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
  "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u00a0";
const CP852_HIGH =
  "ÇüéâäůćçłëŐőîŹÄĆÉĹĺôöĽľŚśÖÜŤťŁ×čáíóúĄąŽžĘę¬źČş«»" +
  "░▒▓│┤ÁÂĚŞ╣║╗╝Żż┐└┴┬├─┼Ăă╚╔╩╦╠═╬¤đĐĎËďŇÍÎě┘┌█▄ŢŮ▀" +
  "ÓßÔŃńňŠšŔÚŕŰýÝţ´\u00ad˝˛ˇ˘§÷¸°¨˙űŘř■\u00a0";
const HIGH: Record<CodePage, string> = { 437: CP437_HIGH, 852: CP852_HIGH, 1252: CP1252_HIGH, 1250: CP1250_HIGH };

export type CodePage = 437 | 852 | 1252 | 1250;

/**
 * The order that breaks a tie the scores and the archive name leave open:
 * the OEM pages first (cp437, then cp852: Windows zip tools and RAR4 write
 * names in the OEM code page), then the ANSI pages (cp1252, then cp1250).
 * income.yaml `archive_code_pages` moves the pages it lists to the front
 * (tieOrder).
 */
export const DEFAULT_CODE_PAGE_ORDER: readonly CodePage[] = [437, 852, 1252, 1250];

/** "cp852" for 852: the name income.yaml and the scan output use. */
export const codePageName = (cp: CodePage): string => `cp${cp}`;

/** The code page a name like "cp852" stands for; null for any other string. */
export function parseCodePageName(name: string): CodePage | null {
  return DEFAULT_CODE_PAGE_ORDER.find((cp) => codePageName(cp) === name) ?? null;
}

/** The tie order: the preferred pages in their order, then the rest in DEFAULT_CODE_PAGE_ORDER. */
export function tieOrder(prefer: readonly CodePage[] = []): CodePage[] {
  return [...new Set([...prefer, ...DEFAULT_CODE_PAGE_ORDER])];
}

/** Decode raw name bytes with a code page; ASCII bytes map to themselves. */
export function decodeCodePage(bytes: Uint8Array, cp: CodePage): string {
  const high = HIGH[cp];
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

// cp437's Greek and math run (0xE0-0xFE) except ß and µ, which are real
// Latin text: its Greek letters count as symbols, not letters.
const CP437_GREEK_MATH = new Set([...CP437_HIGH.slice(0x60, 0x7f)].filter((c) => c !== "ß" && c !== "µ"));
const CONTROL = /\p{Cc}/u;
const LETTER = /^[\p{Ll}\p{Lu}]$/u;
const PUNCT = /^\p{P}$/u;
const WORD = /^[\p{L}\p{N}]$/u;
const LOWER = /^\p{Ll}$/u;
const UPPER = /^\p{Lu}$/u;
const is = (re: RegExp, c: string | undefined) => c !== undefined && re.test(c);

/**
 * Penalty of one decoded char of a name segment, 0 or 1. ASCII costs
 * nothing. A non-ASCII char costs 1 unless it is a letter (\p{Ll}, \p{Lu};
 * not cp437's Greek/math run) or punctuation (\p{P}): box drawing, block
 * elements, the other symbols (\p{So}, \p{Sm}, \p{Sk}, \p{Sc}), modifier
 * letters (\p{Lm}, e.g. cp1252's ˆ), ª/º (\p{Lo}), fractions and
 * superscripts (\p{No}), a no-break space or a soft hyphen. A letter or
 * punctuation mark still costs 1 when it stands alone (no letter or digit on
 * either side: a stray "ź" where cp437 meant "½"), and a letter when it
 * breaks its word's case (an uppercase letter right after a lowercase one,
 * or a lowercase letter between two uppercase ones: "EspaĄa" for "España").
 */
function charPenalty(chars: string[], i: number): number {
  const c = chars[i]!;
  if (c.charCodeAt(0) < 0x80) return 0;
  const letter = LETTER.test(c) && !CP437_GREEK_MATH.has(c);
  if (!letter && !PUNCT.test(c)) return 1;
  const prev = chars[i - 1];
  const next = chars[i + 1];
  if (!is(WORD, prev) && !is(WORD, next)) return 1;
  if (letter && UPPER.test(c) && is(LOWER, prev)) return 1;
  if (letter && LOWER.test(c) && is(UPPER, prev) && is(UPPER, next)) return 1;
  return 0;
}

/** Penalty of a name segment decoded with `cp`; null when it holds a control char (or an undefined byte). */
function segmentPenalty(seg: Uint8Array, cp: CodePage): number | null {
  const chars = [...decodeCodePage(seg, cp)];
  if (chars.some((c) => CONTROL.test(c))) return null;
  let p = 0;
  for (let i = 0; i < chars.length; i++) p += charPenalty(chars, i);
  return p;
}

/** The distinct "/"-separated segments of the names that are not UTF-8-flagged. */
function codePageSegments(cd: NameList): Uint8Array[] {
  const seen = new Map<string, Uint8Array>();
  for (const e of cd.entries) {
    if (e.flags & UTF8_FLAG) continue;
    let from = 0;
    for (let i = 0; i <= e.name.length; i++) {
      if (i < e.name.length && e.name[i] !== 0x2f) continue;
      const seg = e.name.subarray(from, i);
      from = i + 1;
      if (seg.length > 0) seen.set(String.fromCharCode(...seg), seg);
    }
  }
  return [...seen.values()];
}

/**
 * The penalty of every candidate for the names that are not UTF-8-flagged:
 * the sum over their distinct path segments, each scored once (a top-level
 * dir repeated in every name counts once). Null for a candidate that is out.
 * In tie order.
 */
export function codePagePenalties(cd: NameList, prefer: readonly CodePage[] = []): { cp: CodePage; penalty: number | null }[] {
  return penalties(codePageSegments(cd), tieOrder(prefer));
}

function penalties(segs: Uint8Array[], order: CodePage[]): { cp: CodePage; penalty: number | null }[] {
  return order.map((cp) => {
    let penalty: number | null = 0;
    for (const seg of segs) {
      const p = segmentPenalty(seg, cp);
      if (p === null) {
        penalty = null;
        break;
      }
      penalty += p;
    }
    return { cp, penalty };
  });
}

/** How chooseCodePage decided: the lowest penalty, the archive's own name, or the tie order. */
export type CodePageBy = "score" | "name_match" | "order";

export interface CodePageChoice {
  cp: CodePage;
  by: CodePageBy;
}

/**
 * Code page for the names of a zip (or plain RAR4 names) that are not
 * UTF-8-flagged. Every candidate is scored (codePagePenalties) and the
 * lowest penalty wins. Candidates that decode every name to the same text
 * are one choice, so a tie needs candidates with the lowest penalty that
 * give different names. Such a tie is broken:
 * 1. by the archive's own name, when the top-level dir has non-ASCII bytes
 *    and decodes to the archive's file name without extension (both sides
 *    NFC) with exactly one of the tied choices (`name_match`);
 * 2. else by the tie order, the preferred pages first (`order`): a guess,
 *    which the resolver flags on every root from the archive.
 * Null when every candidate is out: the names are not text in any of them.
 */
export function chooseCodePage(cd: NameList, archivePath: string, prefer: readonly CodePage[] = []): CodePageChoice | null {
  const segs = codePageSegments(cd);
  const scored = penalties(segs, tieOrder(prefer)).filter((s): s is { cp: CodePage; penalty: number } => s.penalty !== null);
  if (scored.length === 0) return null;
  const best = Math.min(...scored.map((s) => s.penalty));
  const tied = scored.filter((s) => s.penalty === best).map((s) => s.cp);
  const groups = new Map<string, CodePage[]>(); // decoded text -> candidates, in tie order
  for (const cp of tied) {
    const text = segs.map((seg) => decodeCodePage(seg, cp)).join("\u0000");
    groups.set(text, [...(groups.get(text) ?? []), cp]);
  }
  const choices = [...groups.values()].map((g) => g[0]!);
  if (choices.length === 1) return { cp: choices[0]!, by: "score" };
  const top = topLevelDir(cd);
  if (top && top.some((b) => b >= 0x80)) {
    const own = basename(archivePath).replace(/\.[^.]*$/, "").normalize("NFC");
    const matches = choices.filter((cp) => decodeCodePage(top, cp).normalize("NFC") === own);
    if (matches.length === 1) return { cp: matches[0]!, by: "name_match" };
  }
  return { cp: choices[0]!, by: "order" };
}

/** The error for an archive whose names chooseCodePage cannot decode. */
export function undecodableNames(archivePath: string): string {
  const pages = DEFAULT_CODE_PAGE_ORDER.map(codePageName).join(", ");
  return `entry names of "${basename(archivePath)}" are not text in any code page tried (${pages}): each gives a control character or an undefined byte`;
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
