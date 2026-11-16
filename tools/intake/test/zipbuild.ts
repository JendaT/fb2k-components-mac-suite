// Minimal zip writer for archive tests: stored (uncompressed) entries with
// exact control over the raw name bytes, the UTF-8 flag (general purpose bit
// 11), the host byte of "version made by" and the stored CRC. Lets a test
// build Windows-codepage names or a corrupt member without any zip tool.

export interface ZipEntry {
  name: string | Uint8Array; // a string is written as UTF-8 bytes
  data: Uint8Array;
  utf8Flag?: boolean; // set general purpose bit 11
  host?: number; // "version made by" host: 0 = MS-DOS (default), 3 = Unix
  badCrc?: boolean; // store a wrong CRC-32 (the member fails its check)
}

const u16 = (n: number) => [n & 0xff, (n >>> 8) & 0xff];
const u32 = (n: number) => [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];

export function buildZip(entries: ZipEntry[], comment: Uint8Array = new Uint8Array()): Uint8Array {
  const chunks: Uint8Array[] = [];
  const central: number[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = typeof e.name === "string" ? new TextEncoder().encode(e.name) : e.name;
    const crc = ((Bun.hash.crc32(e.data) >>> 0) ^ (e.badCrc ? 0xffffffff : 0)) >>> 0;
    const host = e.host ?? 0;
    const extAttr = host === 3 ? (0o100644 << 16) >>> 0 : 0x20;
    // version needed, flags, method 0 (stored), time, date, crc, sizes, name len, extra len
    const common = [
      ...u16(20), ...u16(e.utf8Flag ? 0x0800 : 0), ...u16(0), ...u16(0), ...u16(0x21),
      ...u32(crc), ...u32(e.data.length), ...u32(e.data.length), ...u16(name.length), ...u16(0),
    ];
    const local = new Uint8Array([...u32(0x04034b50), ...common, ...name]);
    chunks.push(local, e.data);
    central.push(
      ...u32(0x02014b50), 20, host, ...common,
      ...u16(0), ...u16(0), ...u16(0), ...u32(extAttr), ...u32(offset), ...name,
    );
    offset += local.length + e.data.length;
  }
  const eocd = [
    ...u32(0x06054b50), ...u16(0), ...u16(0), ...u16(entries.length), ...u16(entries.length),
    ...u32(central.length), ...u32(offset), ...u16(comment.length), ...comment,
  ];
  chunks.push(new Uint8Array(central), new Uint8Array(eocd));
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/** Raw name bytes from ASCII string parts and raw byte parts, e.g. rawName("Caf", [0xe9], "/01.flac"). */
export function rawName(...parts: (string | number[])[]): Uint8Array {
  const bytes: number[] = [];
  for (const p of parts) {
    if (typeof p === "string") {
      for (const ch of p) {
        const c = ch.charCodeAt(0);
        if (c > 0x7f) throw new Error(`rawName: string parts must be ASCII, got ${JSON.stringify(ch)}`);
        bytes.push(c);
      }
    } else bytes.push(...p);
  }
  return new Uint8Array(bytes);
}
