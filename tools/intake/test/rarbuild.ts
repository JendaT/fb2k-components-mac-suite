// Minimal RAR5 writer for archive tests: one stored (method 0) file entry,
// with the compression-algorithm version chosen by the caller. Built at test
// time, so no `rar` binary is needed. Layout per the RAR 5.0 archive format
// technote (rarlab.com/technote.htm): signature, main archive header, file
// header + data, end of archive header; every header is CRC32 + vint size +
// fields.
//
// Compression information (file header) bits 0-5 hold the algorithm version:
// 0 is RAR 5.0's, 1 is RAR 7.0's. 7-Zip lists them as `v6` and `v7`. p7zip
// 17.05 rejects version 1 with "Unsupported Method" even for a stored entry
// (p7zip 16.02 predates RAR 7); 7-Zip 26.03 (7zz) extracts it.

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

const u32 = (n: number) => [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];
const crc32 = (b: Uint8Array) => Bun.hash.crc32(b) >>> 0;

/** A header block: CRC32 of (size vint + body), size vint, body. */
function block(body: number[]): number[] {
  const sized = [...vint(body.length), ...body];
  return [...u32(crc32(new Uint8Array(sized))), ...sized];
}

export function buildRar5Stored(name: string, data: Uint8Array, algoVersion: 0 | 1): Uint8Array {
  const signature = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00];
  const main = block([...vint(1), ...vint(0), ...vint(0)]); // type 1, no header flags, no archive flags
  const nameBytes = [...new TextEncoder().encode(name)];
  const dictBits = 8; // 128 KiB << 8 = 32 MiB, as RAR writes for small files
  const compression = algoVersion | (0 << 7) | (dictBits << 10); // method 0 = stored
  const file = block([
    ...vint(2), // type: file header
    ...vint(0x0002), // header flags: data area present
    ...vint(data.length), // data size
    ...vint(0x0004), // file flags: data CRC32 present
    ...vint(data.length), // unpacked size
    ...vint(0o100644), // attributes (Unix mode)
    ...u32(crc32(data)),
    ...vint(compression),
    ...vint(1), // host OS: Unix
    ...vint(nameBytes.length),
    ...nameBytes,
  ]);
  const end = block([...vint(5), ...vint(0), ...vint(0)]); // type 5, no flags, last volume
  return new Uint8Array([...signature, ...main, ...file, ...data, ...end]);
}
